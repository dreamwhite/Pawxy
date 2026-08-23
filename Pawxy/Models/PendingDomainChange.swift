//
//  PendingDomainChange.swift
//  Pawxy
//

import Combine
import Foundation

nonisolated enum PendingDomainChange: Identifiable, Codable, Equatable, Sendable {
    case add(LocalDomain)
    case update(original: LocalDomain, updated: LocalDomain)
    case delete(LocalDomain)
    case resolveConflict(domain: LocalDomain, keeping: DomainDirectiveSource)

    var id: UUID {
        switch self {
        case let .add(domain), let .delete(domain):
            domain.id
        case let .update(original, _):
            original.id
        case let .resolveConflict(domain, _):
            domain.id
        }
    }

    var currentDomain: LocalDomain? {
        switch self {
        case let .add(domain), let .update(_, domain):
            domain
        case .delete:
            nil
        case let .resolveConflict(domain, source):
            source.domainDefinition(fallback: domain)
        }
    }

    var originalDomain: LocalDomain? {
        switch self {
        case .add:
            nil
        case let .update(original, _), let .delete(original):
            original
        case let .resolveConflict(domain, _):
            domain
        }
    }
}

@MainActor
final class PendingDomainChanges: ObservableObject {
    @Published private(set) var changes: [PendingDomainChange] = [] {
        didSet { save() }
    }

    private let fileURL: URL
    private let persistsChanges: Bool

    init(
        fileURL: URL = PendingDomainChanges.defaultFileURL,
        persistsChanges: Bool = true
    ) {
        self.fileURL = fileURL
        self.persistsChanges = persistsChanges
        load()
    }

    var isEmpty: Bool { changes.isEmpty }
    var count: Int { changes.count }

    func stageAdd(_ domain: LocalDomain) {
        replace(.add(domain))
    }

    func stageUpdate(original: LocalDomain, updated: LocalDomain) {
        if let existing = change(for: original.id) {
            switch existing {
            case .add:
                replace(.add(updated))
            case let .update(firstOriginal, _):
                if firstOriginal == updated {
                    remove(id: original.id)
                } else {
                    replace(.update(original: firstOriginal, updated: updated))
                }
            case .delete:
                break
            case .resolveConflict:
                break
            }
        } else if original != updated {
            replace(.update(original: original, updated: updated))
        }
    }

    func stageDelete(_ domain: LocalDomain) {
        if let existing = change(for: domain.id) {
            switch existing {
            case .add:
                remove(id: domain.id)
            case let .update(original, _):
                replace(.delete(original))
            case .delete:
                break
            case .resolveConflict:
                break
            }
        } else {
            replace(.delete(domain))
        }
    }

    func stageConflictResolution(
        for domain: LocalDomain,
        keeping source: DomainDirectiveSource
    ) {
        replace(.resolveConflict(domain: domain, keeping: source))
    }

    func discardAll() {
        changes.removeAll()
    }

    func domains(applyingTo base: [LocalDomain]) -> [LocalDomain] {
        var byID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        for change in changes {
            switch change {
            case let .add(domain), let .update(_, domain):
                byID[domain.id] = domain
            case let .delete(domain):
                byID.removeValue(forKey: domain.id)
            case let .resolveConflict(domain, source):
                byID[domain.id] = source.domainDefinition(fallback: domain)
            }
        }
        return byID.values.sorted {
            $0.domain.localizedStandardCompare($1.domain) == .orderedAscending
        }
    }

    func change(for id: UUID) -> PendingDomainChange? {
        changes.first { $0.id == id }
    }

    private func replace(_ change: PendingDomainChange) {
        changes.removeAll { $0.id == change.id }
        changes.append(change)
    }

    private func remove(id: UUID) {
        changes.removeAll { $0.id == id }
    }

    private func load() {
        guard persistsChanges,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PendingDomainChange].self, from: data)
        else {
            return
        }
        changes = decoded
    }

    private func save() {
        guard persistsChanges else { return }
        do {
            if changes.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(changes).write(to: fileURL, options: .atomic)
        } catch {
            // Pending changes remain available in memory even if persistence fails.
        }
    }

    nonisolated private static var defaultFileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Pawxy", isDirectory: true)
            .appendingPathComponent("pending-changes.json", isDirectory: false)
    }
}
