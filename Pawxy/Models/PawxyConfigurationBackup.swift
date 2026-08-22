//
//  PawxyConfigurationBackup.swift
//  Pawxy
//

import Foundation

struct PawxyConfigurationBackup: Codable, Equatable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let mappings: [Mapping]

    init(domains: [LocalDomain], exportedAt: Date = Date()) {
        formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        mappings = domains.map(Mapping.init).sorted {
            $0.domain.localizedStandardCompare($1.domain) == .orderedAscending
        }
    }

    struct Mapping: Codable, Equatable, Identifiable {
        var id: String { domain.lowercased() }

        let domain: String
        let address: String
        let wildcard: Bool
        let enabled: Bool

        nonisolated init(_ domain: LocalDomain) {
            self.domain = domain.domain
            address = domain.address
            wildcard = domain.wildcard
            enabled = domain.enabled
        }

        nonisolated var localDomain: LocalDomain {
            LocalDomain(
                domain: domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                address: address.trimmingCharacters(in: .whitespacesAndNewlines),
                wildcard: wildcard,
                enabled: enabled
            )
        }
    }
}
