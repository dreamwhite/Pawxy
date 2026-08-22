//
//  main.swift
//  PawxyHelper
//

import Foundation
import Security

private final class PawxyHelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PawxyPrivilegedHelperService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard PawxyClientCodeValidator.isTrusted(connection: connection) else {
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: PawxyPrivilegedHelperXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private enum PawxyClientCodeValidator {
    static func isTrusted(connection: NSXPCConnection) -> Bool {
        var guestCode: SecCode?
        let attributes = [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode,
              let requirement = bundledAppRequirement(),
              SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess
        else {
            return false
        }
        return true
    }

    private static func bundledAppRequirement() -> SecRequirement? {
        let contentsURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appExecutableURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Pawxy")

        var appCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appExecutableURL as CFURL, [], &appCode)
                == errSecSuccess,
              let appCode
        else {
            return nil
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(appCode, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }
}

private final class PawxyPrivilegedHelperService: NSObject, PawxyPrivilegedHelperXPC {
    private let operationQueue = DispatchQueue(label: "com.dreamcorp.Pawxy.Helper.operations")

    func ping(withReply reply: @escaping (Int) -> Void) {
        reply(PawxyPrivilegedHelperConstants.protocolVersion)
    }

    func perform(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        operationQueue.async {
            do {
                let request = try JSONDecoder().decode(
                    PawxyPrivilegedRequest.self,
                    from: requestData
                )
                guard request.protocolVersion == PawxyPrivilegedHelperConstants.protocolVersion else {
                    throw HelperError.incompatibleClient
                }

                let response = try PawxyPrivilegedOperationExecutor().perform(request.operation)
                reply(try JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }
}

private struct PawxyPrivilegedOperationExecutor {
    private let fileManager = FileManager.default

    func perform(_ operation: PawxyPrivilegedOperation) throws -> PawxyPrivilegedResponse {
        switch operation {
        case let .transact(prefix, changes, restartDnsmasq):
            let paths = try ValidatedPaths(prefix: prefix)
            try transact(changes, paths: paths, restartDnsmasq: restartDnsmasq)
            return PawxyPrivilegedResponse(message: "The configuration was applied successfully.")

        case let .restartDnsmasq(prefix):
            let paths = try ValidatedPaths(prefix: prefix)
            try validateDnsmasq(paths: paths)
            try activateDnsmasq(paths: paths)
            return PawxyPrivilegedResponse(message: "dnsmasq was restarted successfully.")
        }
    }

    private func transact(
        _ changes: [PawxyPrivilegedFileChange],
        paths: ValidatedPaths,
        restartDnsmasq: Bool
    ) throws {
        guard !changes.isEmpty, changes.count <= 128 else {
            throw HelperError.invalidRequest("The file transaction is empty or too large.")
        }

        let destinations = changes.map(\.destination)
        guard Set(destinations).count == destinations.count else {
            throw HelperError.invalidRequest("A destination appears more than once.")
        }
        for change in changes {
            try validate(change, paths: paths)
        }

        let backupDirectory = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("Pawxy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: backupDirectory) }

        let snapshots = try changes.enumerated().map { index, change in
            try snapshot(change.destination, index: index, in: backupDirectory)
        }

        do {
            for change in changes {
                try apply(change)
            }
            if restartDnsmasq {
                try validateDnsmasq(paths: paths)
                try activateDnsmasq(paths: paths)
            }
        } catch {
            for snapshot in snapshots.reversed() {
                try? restore(snapshot)
            }
            if restartDnsmasq {
                try? activateDnsmasq(paths: paths)
            }
            throw error
        }
    }

    private func validate(
        _ change: PawxyPrivilegedFileChange,
        paths: ValidatedPaths
    ) throws {
        let destination = URL(fileURLWithPath: change.destination).standardizedFileURL.path
        guard destination == change.destination,
              paths.allows(destination),
              !containsSymbolicLink(destination)
        else {
            throw HelperError.forbiddenPath(change.destination)
        }

        if case let .write(_, contents) = change {
            guard contents.count <= 1_048_576,
                  let text = String(data: contents, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { $0.value == 0 })
            else {
                throw HelperError.invalidRequest("Configuration contents are not valid UTF-8.")
            }
        }
    }

    private func containsSymbolicLink(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                return true
            }
            url.deleteLastPathComponent()
        }
        return false
    }

    private func snapshot(_ path: String, index: Int, in directory: URL) throws -> Snapshot {
        guard fileManager.fileExists(atPath: path) else {
            return Snapshot(destination: path, backup: nil, attributes: nil)
        }
        let backup = directory.appendingPathComponent(String(index))
        try fileManager.copyItem(atPath: path, toPath: backup.path)
        return Snapshot(
            destination: path,
            backup: backup,
            attributes: try? fileManager.attributesOfItem(atPath: path)
        )
    }

    private func apply(_ change: PawxyPrivilegedFileChange) throws {
        switch change {
        case let .write(destination, contents):
            let destinationURL = URL(fileURLWithPath: destination)
            let directory = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            let temporaryURL = directory.appendingPathComponent(".pawxy-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporaryURL) }
            try contents.write(to: temporaryURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryURL.path)
            if fileManager.fileExists(atPath: destination) {
                try fileManager.removeItem(atPath: destination)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)

        case let .remove(destination):
            if fileManager.fileExists(atPath: destination) {
                try fileManager.removeItem(atPath: destination)
            }
        }
    }

    private func restore(_ snapshot: Snapshot) throws {
        if fileManager.fileExists(atPath: snapshot.destination) {
            try fileManager.removeItem(atPath: snapshot.destination)
        }
        guard let backup = snapshot.backup else { return }
        try fileManager.copyItem(atPath: backup.path, toPath: snapshot.destination)
        if let attributes = snapshot.attributes {
            try fileManager.setAttributes(attributes, ofItemAtPath: snapshot.destination)
        }
    }

    private func validateDnsmasq(paths: ValidatedPaths) throws {
        let result = try run(paths.dnsmasqExecutable, arguments: ["--test", "-C", paths.rootConfiguration])
        guard result.status == 0 else {
            throw HelperError.commandFailed("dnsmasq validation", result.output)
        }
    }

    private func activateDnsmasq(paths: ValidatedPaths) throws {
        let service = "system/homebrew.mxcl.dnsmasq"
        let current = try run("/bin/launchctl", arguments: ["print", service])
        let result = current.status == 0
            ? try run("/bin/launchctl", arguments: ["kickstart", "-k", service])
            : try run(paths.brewExecutable, arguments: ["services", "start", "dnsmasq"])
        guard result.status == 0 else {
            throw HelperError.commandFailed("dnsmasq restart", result.output)
        }
    }

    private func run(_ executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw HelperError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent, error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

private struct ValidatedPaths {
    let prefix: String
    let policy: PawxyPrivilegedPathPolicy

    init(prefix: String) throws {
        guard let policy = PawxyPrivilegedPathPolicy(prefix: prefix) else {
            throw HelperError.invalidHomebrewPrefix
        }
        let executable = "\(prefix)/opt/dnsmasq/sbin/dnsmasq"
        let brew = "\(prefix)/bin/brew"
        guard FileManager.default.isExecutableFile(atPath: executable),
              FileManager.default.isExecutableFile(atPath: brew)
        else {
            throw HelperError.invalidHomebrewPrefix
        }
        self.prefix = prefix
        self.policy = policy
    }

    var rootConfiguration: String { policy.rootConfiguration }
    var dnsmasqExecutable: String { "\(prefix)/opt/dnsmasq/sbin/dnsmasq" }
    var brewExecutable: String { "\(prefix)/bin/brew" }

    func allows(_ path: String) -> Bool {
        policy.allows(path)
    }
}

private struct Snapshot {
    let destination: String
    let backup: URL?
    let attributes: [FileAttributeKey: Any]?
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

private enum HelperError: LocalizedError {
    case incompatibleClient
    case invalidHomebrewPrefix
    case invalidRequest(String)
    case forbiddenPath(String)
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .incompatibleClient:
            return "Pawxy and its privileged helper are different versions. Reinstall the helper."
        case .invalidHomebrewPrefix:
            return "The Homebrew installation could not be validated."
        case let .invalidRequest(detail):
            return "The privileged request was rejected: \(detail)"
        case let .forbiddenPath(path):
            return "The privileged helper refused to modify \(path)."
        case let .commandFailed(action, detail):
            return detail.isEmpty ? "The \(action) failed." : "The \(action) failed: \(detail)"
        }
    }
}

private let delegate = PawxyHelperDelegate()
private let listener = NSXPCListener(
    machServiceName: PawxyPrivilegedHelperConstants.machServiceName
)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
