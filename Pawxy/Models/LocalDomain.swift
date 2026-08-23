//
//  LocalDomain.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import Foundation

nonisolated struct LocalDomain: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var domain: String
    var address: String
    var wildcard: Bool
    var enabled: Bool
    var origin: LocalDomainOrigin

    init(
        id: UUID = UUID(),
        domain: String,
        address: String,
        wildcard: Bool = false,
        enabled: Bool = true,
        origin: LocalDomainOrigin = .manual
    ) {
        self.id = id
        self.domain = domain
        self.address = address
        self.wildcard = wildcard
        self.enabled = enabled
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        domain = try container.decode(String.self, forKey: .domain)
        address = try container.decode(String.self, forKey: .address)
        wildcard = try container.decode(Bool.self, forKey: .wildcard)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        origin = try container.decodeIfPresent(LocalDomainOrigin.self, forKey: .origin) ?? .manual
    }
}

nonisolated enum LocalDomainOrigin: Codable, Equatable, Sendable {
    case manual
    case imported(file: String, line: Int)
    case conflict(sources: [DomainDirectiveSource])

    var label: String {
        switch self {
        case .manual:
            return String(localized: "Created in Pawxy")
        case let .imported(file, line):
            return "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        case let .conflict(sources):
            return String(localized: "Conflict in \(sources.count) directives")
        }
    }
}

nonisolated struct DomainDirectiveSource: Codable, Equatable, Hashable, Sendable {
    let file: String
    let line: Int
    let address: String
    let wildcard: Bool
    let enabled: Bool

    init(
        file: String,
        line: Int,
        address: String = "",
        wildcard: Bool = false,
        enabled: Bool = true
    ) {
        self.file = file
        self.line = line
        self.address = address
        self.wildcard = wildcard
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        line = try container.decode(Int.self, forKey: .line)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        wildcard = try container.decodeIfPresent(Bool.self, forKey: .wildcard) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    var label: String {
        "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
    }

    func domainDefinition(fallback: LocalDomain) -> LocalDomain {
        LocalDomain(
            id: fallback.id,
            domain: fallback.domain,
            address: address.isEmpty ? fallback.address : address,
            wildcard: address.isEmpty ? fallback.wildcard : wildcard,
            enabled: enabled,
            origin: .imported(file: file, line: line)
        )
    }
}
