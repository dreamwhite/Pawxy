//
//  PrivilegedHelperProtocol.swift
//  Pawxy
//

import Foundation

nonisolated enum PawxyPrivilegedHelperConstants {
    static let machServiceName = "com.dreamcorp.Pawxy.Helper"
    static let launchDaemonPlistName = "com.dreamcorp.Pawxy.Helper.plist"
    static let clientBundleIdentifier = "com.dreamcorp.Pawxy"
    static let protocolVersion = 1
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
    var resolverDirectory: String { "/etc/resolver" }

    func allows(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path else { return false }

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
