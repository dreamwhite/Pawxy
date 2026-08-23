//
//  PendingDomainChange.swift
//  Pawxy
//

import Combine
import Foundation

nonisolated enum PendingDomainChange: Identifiable, Equatable, Sendable {
    case add(LocalDomain)
    case update(original: LocalDomain, updated: LocalDomain)
    case delete(LocalDomain)

    var id: UUID {
        switch self {
        case let .add(domain), let .delete(domain):
            domain.id
        case let .update(original, _):
            original.id
        }
    }

    var currentDomain: LocalDomain? {
        switch self {
        case let .add(domain), let .update(_, domain):
            domain
        case .delete:
            nil
        }
    }

    var originalDomain: LocalDomain? {
        switch self {
        case .add:
            nil
        case let .update(original, _), let .delete(original):
            original
        }
    }
}

@MainActor
final class PendingDomainChanges: ObservableObject {
    @Published private(set) var changes: [PendingDomainChange] = []

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
            }
        } else {
            replace(.delete(domain))
        }
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
}
