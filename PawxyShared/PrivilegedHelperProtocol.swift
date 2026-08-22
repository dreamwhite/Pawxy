//
//  PrivilegedHelperProtocol.swift
//  Pawxy
//

import Foundation

nonisolated enum PawxyPrivilegedHelperConstants {
    static let machServiceName = "com.dreamcorp.Pawxy.Helper"
    static let launchDaemonPlistName = "com.dreamcorp.Pawxy.Helper.plist"
    static let clientBundleIdentifier = "com.dreamcorp.Pawxy"
    static let protocolVersion = 2
}

nonisolated enum PawxyPrivilegedHelperBundleLayout {
    static func containingAppURL(forHelperExecutable executableURL: URL) -> URL? {
        let helperURL = executableURL.standardizedFileURL
        guard helperURL.lastPathComponent == "PawxyHelper" else { return nil }

        let resourcesURL = helperURL.deletingLastPathComponent()
        guard resourcesURL.lastPathComponent == "Resources" else { return nil }

        let contentsURL = resourcesURL.deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents" else { return nil }

        let appURL = contentsURL.deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { return nil }
        return appURL
    }
}

@objc(PawxyPrivilegedHelperXPC)
nonisolated protocol PawxyPrivilegedHelperXPC {
    func ping(withReply reply: @escaping (Int) -> Void)
    func perform(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

nonisolated struct PawxyPrivilegedRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let operation: PawxyPrivilegedOperation

    init(operation: PawxyPrivilegedOperation) {
        protocolVersion = PawxyPrivilegedHelperConstants.protocolVersion
        self.operation = operation
    }
}

nonisolated enum PawxyPrivilegedOperation: Codable, Equatable, Sendable {
    case transact(
        homebrewPrefix: String,
        changes: [PawxyPrivilegedFileChange],
        restartDnsmasq: Bool
    )
    case restartDnsmasq(homebrewPrefix: String)
}

nonisolated enum PawxyPrivilegedFileChange: Codable, Equatable, Sendable {
    case write(destination: String, contents: Data)
    case remove(destination: String)

    var destination: String {
        switch self {
        case let .write(destination, _), let .remove(destination):
            destination
        }
    }
}

nonisolated struct PawxyPrivilegedResponse: Codable, Equatable, Sendable {
    let message: String
}

nonisolated struct PawxyPrivilegedPathPolicy: Sendable {
    let prefix: String

    init?(prefix: String) {
        guard prefix == "/opt/homebrew" || prefix == "/usr/local" else { return nil }
        self.prefix = prefix
    }

    var rootConfiguration: String { "\(prefix)/etc/dnsmasq.conf" }
    var configurationDirectory: String { "\(prefix)/etc/dnsmasq.d" }
    // `/etc` is a system symlink to `/private/etc` on macOS. Use the canonical
    // path so the helper can keep rejecting every symlink in privileged file
    // transactions without blocking the legitimate resolver directory.
    var resolverDirectory: String { "/private/etc/resolver" }

    func allows(_ path: String) -> Bool {
        if path == rootConfiguration {
            return true
        }
        if path.hasPrefix(configurationDirectory + "/") {
            let relativePath = String(path.dropFirst(configurationDirectory.count + 1))
            return !relativePath.isEmpty
                && !relativePath.contains("/")
                && relativePath.hasSuffix(".conf")
        }
        guard path.hasPrefix(resolverDirectory + "/") else { return false }
        let name = String(path.dropFirst(resolverDirectory.count + 1))
        return !name.isEmpty
            && !name.contains("/")
            && name.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#,
                options: .regularExpression
            ) != nil
    }
}
