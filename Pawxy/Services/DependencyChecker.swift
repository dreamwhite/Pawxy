//
//  DependencyChecker.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import Foundation

enum DependencyAvailability: Equatable {
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

struct DevelopmentEnvironmentStatus: Equatable {
    let homebrew: DependencyAvailability
    let dnsmasq: DependencyAvailability

    var isReady: Bool {
        homebrew.isAvailable && dnsmasq.isAvailable
    }
}

struct DependencyChecker {
    private let homebrewCandidates: [String]
    private let dnsmasqCandidates: [String]
    private let fileManager: FileManager

    init(
        homebrewCandidates: [String] = DependencyChecker.defaultCandidates(
            executable: "brew",
            standardPaths: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        ),
        dnsmasqCandidates: [String] = DependencyChecker.defaultCandidates(
            executable: "dnsmasq",
            standardPaths: ["/opt/homebrew/sbin/dnsmasq", "/usr/local/sbin/dnsmasq"]
        ),
        fileManager: FileManager = .default
    ) {
        self.homebrewCandidates = homebrewCandidates
        self.dnsmasqCandidates = dnsmasqCandidates
        self.fileManager = fileManager
    }

    func check() -> DevelopmentEnvironmentStatus {
        DevelopmentEnvironmentStatus(
            homebrew: availability(in: homebrewCandidates),
            dnsmasq: availability(in: dnsmasqCandidates)
        )
    }

    private func availability(in candidates: [String]) -> DependencyAvailability {
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            return .missing
        }

        return .available(at: path)
    }

    private static func defaultCandidates(
        executable: String,
        standardPaths: [String]
    ) -> [String] {
        let pathCandidates = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map { "\($0)/\(executable)" }

        return standardPaths + pathCandidates
    }
}
