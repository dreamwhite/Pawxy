//
//  DiscoveredDomain.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import Foundation

nonisolated struct DiscoveredDomain: Identifiable, Equatable, Sendable {
    let id: UUID
    let domain: String
    let address: String
    let wildcard: Bool
    let enabled: Bool
    let sourceFile: String
    let sourceLine: Int
    let conflictingSources: [DomainDirectiveSource]

    init(
        id: UUID = UUID(),
        domain: String,
        address: String,
        wildcard: Bool,
        enabled: Bool = true,
        sourceFile: String,
        sourceLine: Int,
        conflictingSources: [DomainDirectiveSource] = []
    ) {
        self.id = id
        self.domain = domain
        self.address = address
        self.wildcard = wildcard
        self.enabled = enabled
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
        self.conflictingSources = conflictingSources
    }

    var localDomain: LocalDomain {
        LocalDomain(
            domain: domain,
            address: address,
            wildcard: wildcard,
            enabled: enabled,
            origin: conflictingSources.isEmpty
                ? .imported(file: sourceFile, line: sourceLine)
                : .conflict(sources: conflictingSources)
        )
    }
}
