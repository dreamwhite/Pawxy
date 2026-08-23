//
//  DependencyChecker.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import Foundation

nonisolated enum DependencyAvailability: Equatable, Sendable {
    case available(at: String)
    case missing

    var isAvailable: Bool {
        if case .available = self {
            return true
        }

        return false
    }

    var path: String? {
        if case let .available(path) = self {
            return path
        }

        return nil
    }
}

nonisolated struct DevelopmentEnvironmentStatus: Equatable, Sendable {
    let homebrew: DependencyAvailability
    let dnsmasq: DependencyAvailability
    let service: EnvironmentComponentStatus
    let configuration: EnvironmentComponentStatus
    let managedDirectory: EnvironmentComponentStatus

    init(
        homebrew: DependencyAvailability,
        dnsmasq: DependencyAvailability,
        service: EnvironmentComponentStatus = .unknown,
        configuration: EnvironmentComponentStatus = .unknown,
        managedDirectory: EnvironmentComponentStatus = .unknown
    ) {
        self.homebrew = homebrew
        self.dnsmasq = dnsmasq
        self.service = service
        self.configuration = configuration
        self.managedDirectory = managedDirectory
    }

    var isReady: Bool {
        hasRequiredTools
            && service.isReady
            && configuration.isReady
            && managedDirectory.isReady
    }

    var hasRequiredTools: Bool {
        homebrew.isAvailable && dnsmasq.isAvailable
    }
}

nonisolated enum EnvironmentComponentStatus: Equatable, Sendable {
    case ready(String)
    case warning(String)
    case failed(String)
    case unknown

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var detail: String {
        switch self {
        case let .ready(detail), let .warning(detail), let .failed(detail): detail
        case .unknown: String(localized: "Not checked")
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

nonisolated struct DependencyChecker {
    private let homebrewCandidates: [String]
    private let dnsmasqCandidates: [String]
    private let fileManager: FileManager

    init(
        homebrewCandidates: [String] = DependencyChecker.defaultCandidates(
            standardPaths: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        ),
        dnsmasqCandidates: [String] = DependencyChecker.defaultCandidates(
            standardPaths: ["/opt/homebrew/sbin/dnsmasq", "/usr/local/sbin/dnsmasq"]
        ),
        fileManager: FileManager = .default
    ) {
        self.homebrewCandidates = homebrewCandidates
        self.dnsmasqCandidates = dnsmasqCandidates
        self.fileManager = fileManager
    }

    func check() -> DevelopmentEnvironmentStatus {
        let homebrew = availability(in: homebrewCandidates)
        let dnsmasq = availability(in: dnsmasqCandidates)
        guard let brewPath = homebrew.path, let dnsmasqPath = dnsmasq.path else {
            return DevelopmentEnvironmentStatus(
                homebrew: homebrew,
                dnsmasq: dnsmasq,
                service: .failed(String(localized: "dnsmasq is not installed")),
                configuration: .unknown,
                managedDirectory: .unknown
            )
        }

        let prefix = URL(fileURLWithPath: brewPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let rootConfiguration = "\(prefix)/etc/dnsmasq.conf"
        let managedDirectory = "\(prefix)/etc/dnsmasq.d"

        return DevelopmentEnvironmentStatus(
            homebrew: homebrew,
            dnsmasq: dnsmasq,
            service: serviceStatus(),
            configuration: configurationStatus(
                executable: dnsmasqPath,
                rootConfiguration: rootConfiguration
            ),
            managedDirectory: managedDirectoryStatus(
                rootConfiguration: rootConfiguration,
                managedDirectory: managedDirectory
            )
        )
    }

    private func serviceStatus() -> EnvironmentComponentStatus {
        let result = run(
            "/usr/bin/dig",
            arguments: ["+time=1", "+tries=1", "@127.0.0.1", "localhost", "A"]
        )
        return result.status == 0
            ? .ready(String(localized: "Listening on 127.0.0.1:53"))
            : .failed(String(localized: "dnsmasq is not listening on 127.0.0.1:53"))
    }

    private func configurationStatus(
        executable: String,
        rootConfiguration: String
    ) -> EnvironmentComponentStatus {
        guard fileManager.fileExists(atPath: rootConfiguration) else {
            return .failed(String(localized: "The dnsmasq.conf file was not found"))
        }
        let result = run(executable, arguments: ["--test", "-C", rootConfiguration])
        if result.status == 0 {
            return .ready(String(localized: "dnsmasq configuration is valid"))
        }
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty
            ? String(localized: "dnsmasq configuration validation failed")
            : detail)
    }

    private func managedDirectoryStatus(
        rootConfiguration: String,
        managedDirectory: String
    ) -> EnvironmentComponentStatus {
        guard let contents = try? String(contentsOfFile: rootConfiguration, encoding: .utf8) else {
            return .unknown
        }
        let includesDirectory = contents.components(separatedBy: .newlines).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.hasPrefix("conf-dir=") else { return false }
            let value = String(line.dropFirst("conf-dir=".count))
                .split(separator: ",", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            return URL(fileURLWithPath: value).standardizedFileURL.path
                == URL(fileURLWithPath: managedDirectory).standardizedFileURL.path
        }
        return includesDirectory
            ? .ready(String(localized: "dnsmasq.d is included"))
            : .warning(String(localized: "dnsmasq.d is not included by dnsmasq.conf"))
    }

    private func run(_ executable: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func availability(in candidates: [String]) -> DependencyAvailability {
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            return .missing
        }

        return .available(at: path)
    }

    private static func defaultCandidates(standardPaths: [String]) -> [String] {
        standardPaths
    }
}
