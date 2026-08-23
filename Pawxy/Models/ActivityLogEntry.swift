//
//  ActivityLogEntry.swift
//  Pawxy
//

import Foundation

nonisolated struct ActivityLogEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case configuration
        case resolver
        case service
        case backup
        case diagnostics
    }

    let id: UUID
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
    let succeeded: Bool

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        title: String,
        detail: String = "",
        succeeded: Bool = true
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
        self.succeeded = succeeded
    }
}
