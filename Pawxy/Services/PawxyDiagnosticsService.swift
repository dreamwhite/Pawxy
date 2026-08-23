//
//  PawxyDiagnosticsService.swift
//  Pawxy
//

import Foundation

nonisolated struct PawxyDiagnosticsService {
    func report(
        status: DevelopmentEnvironmentStatus,
        domains: [LocalDomain],
        recentActivity: [ActivityLogEntry]
    ) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let enabled = domains.filter(\.enabled).count
        let conflicts = domains.filter {
            if case .conflict = $0.origin { return true }
            return false
        }.count
        let manager = DnsmasqConfigurationManager()

        var lines = [
            "Pawxy diagnostics",
            "Version: \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(Self.architecture)",
            "Homebrew: \(status.homebrew.path ?? "missing")",
            "dnsmasq: \(status.dnsmasq.path ?? "missing")",
            "DNS service: \(status.service.detail)",
            "Configuration: \(status.configuration.detail)",
            "Managed directory: \(status.managedDirectory.detail)",
            "Root configuration: \(manager.rootConfigurationPath)",
            "Configuration directory: \(manager.configurationDirectoryPath)",
            "Mappings: \(domains.count) total, \(enabled) enabled, \(conflicts) conflicts",
            "",
            "Recent activity (domain names and file contents omitted):"
        ]

        lines.append(contentsOf: recentActivity.prefix(20).map {
            "- \($0.date.formatted(.iso8601)) | \($0.kind.rawValue) | \($0.succeeded ? "ok" : "failed") | \($0.title)"
        })
        return lines.joined(separator: "\n") + "\n"
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
