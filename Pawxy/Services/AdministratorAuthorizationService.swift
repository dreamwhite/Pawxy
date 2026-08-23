//
//  AdministratorAuthorizationService.swift
//  Pawxy
//

import Foundation

nonisolated enum AdministratorFileChange: Sendable {
    case write(destination: String, contents: Data)
    case remove(destination: String)

    var destination: String {
        switch self {
        case let .write(destination, _), let .remove(destination):
            destination
        }
    }
}

/// Applies the small, allow-listed set of system changes Pawxy needs through
/// macOS' standard administrator authorization prompt.
nonisolated struct AdministratorAuthorizationService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func transact(
        homebrewPrefix: String,
        changes: [AdministratorFileChange],
        restartDnsmasq: Bool
    ) throws {
        let paths = try ValidatedPaths(prefix: homebrewPrefix, fileManager: fileManager)
        guard !changes.isEmpty, changes.count <= 128 else {
            throw AuthorizationError.invalidRequest
        }
        guard Set(changes.map(\.destination)).count == changes.count else {
            throw AuthorizationError.duplicateDestination
        }
        for change in changes {
            guard paths.policy.allows(change.destination),
                  !containsSymbolicLink(in: change.destination)
            else {
                throw AuthorizationError.forbiddenPath(change.destination)
            }
            if case let .write(_, contents) = change {
                guard contents.count <= 1_048_576,
                      String(data: contents, encoding: .utf8) != nil,
                      !contents.contains(0)
                else {
                    throw AuthorizationError.invalidContents
                }
            }
        }

        try executeWithAdministratorPrivileges(
            script(
                paths: paths,
                changes: changes,
                restartDnsmasq: restartDnsmasq
            )
        )
    }

    func restartDnsmasq(homebrewPrefix: String) throws {
        let paths = try ValidatedPaths(prefix: homebrewPrefix, fileManager: fileManager)
        try executeWithAdministratorPrivileges(
            script(paths: paths, changes: [], restartDnsmasq: true)
        )
    }

    private func script(
        paths: ValidatedPaths,
        changes: [AdministratorFileChange],
        restartDnsmasq: Bool
    ) -> String {
        var lines = [
            "#!/bin/zsh",
            "set -eu",
            "backup_dir=$(/usr/bin/mktemp -d /private/var/tmp/Pawxy.XXXXXX)",
            "committed=0",
            "cleanup() {",
            "  status=$?",
            "  if [[ $committed -eq 0 ]]; then"
        ]

        for (index, change) in changes.enumerated().reversed() {
            let destination = shellQuote(change.destination)
            lines.append("    if [[ -e \"$backup_dir/\(index)\" ]]; then")
            lines.append("      /bin/mkdir -p \(shellQuote(URL(fileURLWithPath: change.destination).deletingLastPathComponent().path))")
            lines.append("      /bin/cp -p \"$backup_dir/\(index)\" \(destination)")
            lines.append("    else")
            lines.append("      /bin/rm -f \(destination)")
            lines.append("    fi")
        }

        lines += [
            "  fi",

            restartDnsmasq
                ? "  if [[ $committed -eq 0 ]]; then \(shellQuote(paths.dnsmasqExecutable)) --test -C \(shellQuote(paths.rootConfiguration)) >/dev/null 2>&1 && /bin/launchctl kickstart -k system/homebrew.mxcl.dnsmasq >/dev/null 2>&1 || true; fi"
                : "  true",
            "  /bin/rm -rf \"$backup_dir\"",
            "  exit $status",
            "}",
            "trap cleanup EXIT",
            "trap 'exit 1' HUP INT TERM"
        ]

        for (index, change) in changes.enumerated() {
            let destination = shellQuote(change.destination)
            let directory = shellQuote(
                URL(fileURLWithPath: change.destination).deletingLastPathComponent().path
            )
            lines.append("if [[ -e \(destination) ]]; then /bin/cp -p \(destination) \"$backup_dir/\(index)\"; fi")

            switch change {
            case let .write(_, contents):
                let temporary = shellQuote(
                    "\(change.destination).pawxy-\(UUID().uuidString).tmp"
                )
                lines.append("/bin/mkdir -p \(directory)")
                lines.append("/usr/bin/printf '%s' \(shellQuote(contents.base64EncodedString())) | /usr/bin/base64 -D > \(temporary)")
                lines.append("/bin/chmod 0644 \(temporary)")
                lines.append("/bin/mv -f \(temporary) \(destination)")
            case .remove:
                lines.append("/bin/rm -f \(destination)")
            }
        }

        if restartDnsmasq {
            lines += [
                "\(shellQuote(paths.dnsmasqExecutable)) --test -C \(shellQuote(paths.rootConfiguration))",
                "if /bin/launchctl print system/homebrew.mxcl.dnsmasq >/dev/null 2>&1; then",
                "  /bin/launchctl kickstart -k system/homebrew.mxcl.dnsmasq",
                "else",
                "  \(shellQuote(paths.brewExecutable)) services start dnsmasq",
                "fi"
            ]
        }

        lines.append("committed=1")
        return lines.joined(separator: "\n") + "\n"
    }

    private func executeWithAdministratorPrivileges(_ script: String) throws {
        let encodedScript = Data(script.utf8).base64EncodedString()
        let command = "/usr/bin/printf '%s' \(shellQuote(encodedScript)) | /usr/bin/base64 -D | /bin/zsh"
        let appleScript = "do shell script \(appleScriptLiteral(command)) with administrator privileges"

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AuthorizationError.couldNotRequestAuthorization(error.localizedDescription)
        }

        let detail = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            if detail.contains("User canceled") || detail.contains("(-128)") {
                throw AuthorizationError.cancelled
            }
            throw AuthorizationError.operationFailed(detail)
        }
    }

    private func containsSymbolicLink(in path: String) -> Bool {
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

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func appleScriptLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension AdministratorAuthorizationService {
    nonisolated struct PathPolicy: Sendable {
        let prefix: String

        init?(prefix: String) {
            guard prefix == "/opt/homebrew" || prefix == "/usr/local" else { return nil }
            self.prefix = prefix
        }

        var rootConfiguration: String { "\(prefix)/etc/dnsmasq.conf" }
        var configurationDirectory: String { "\(prefix)/etc/dnsmasq.d" }
        var resolverDirectory: String { "/private/etc/resolver" }

        func allows(_ path: String) -> Bool {
            if path == rootConfiguration { return true }
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

    private struct ValidatedPaths {
        let prefix: String
        let policy: PathPolicy

        init(prefix: String, fileManager: FileManager) throws {
            guard let policy = PathPolicy(prefix: prefix) else {
                throw AuthorizationError.invalidHomebrewInstallation
            }
            let dnsmasqExecutable = "\(prefix)/opt/dnsmasq/sbin/dnsmasq"
            let brewExecutable = "\(prefix)/bin/brew"
            guard fileManager.isExecutableFile(atPath: dnsmasqExecutable),
                  fileManager.isExecutableFile(atPath: brewExecutable)
            else {
                throw AuthorizationError.invalidHomebrewInstallation
            }
            self.prefix = prefix
            self.policy = policy
        }

        var rootConfiguration: String { policy.rootConfiguration }
        var dnsmasqExecutable: String { "\(prefix)/opt/dnsmasq/sbin/dnsmasq" }
        var brewExecutable: String { "\(prefix)/bin/brew" }
    }

    nonisolated enum AuthorizationError: LocalizedError {
        case invalidHomebrewInstallation
        case invalidRequest
        case duplicateDestination
        case forbiddenPath(String)
        case invalidContents
        case cancelled
        case couldNotRequestAuthorization(String)
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidHomebrewInstallation:
                String(localized: "The Homebrew installation could not be validated.")
            case .invalidRequest:
                String(localized: "The administrator operation is empty or too large.")
            case .duplicateDestination:
                String(localized: "A destination appears more than once in the administrator operation.")
            case let .forbiddenPath(path):
                String(localized: "Pawxy refused to modify the unsupported path \(path).")
            case .invalidContents:
                String(localized: "The configuration contents are not valid UTF-8.")
            case .cancelled:
                String(localized: "Administrator authorization was cancelled.")
            case let .couldNotRequestAuthorization(detail):
                String(localized: "Pawxy could not request administrator authorization: \(detail)")
            case let .operationFailed(detail):
                detail.isEmpty
                    ? String(localized: "The administrator operation failed.")
                    : String(localized: "The administrator operation failed: \(detail)")
            }
        }
    }
}
