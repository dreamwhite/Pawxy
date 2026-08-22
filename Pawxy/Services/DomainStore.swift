//
//  DomainStore.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import Combine
import Foundation

@MainActor
final class DomainStore: ObservableObject {
    @Published private(set) var domains: [LocalDomain]
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let persistsChanges: Bool

    init(
        domains: [LocalDomain]? = nil,
        fileURL: URL = DomainStore.defaultFileURL,
        persistsChanges: Bool = true
    ) {
        self.fileURL = fileURL
        self.persistsChanges = persistsChanges

        if let domains {
            self.domains = domains
        } else {
            self.domains = []
            load()
        }
    }

    func add(_ domain: LocalDomain) {
        domains.append(domain)
        sortAndSave()
    }

    func update(_ domain: LocalDomain) {
        guard let index = domains.firstIndex(where: { $0.id == domain.id }) else { return }
        domains[index] = domain
        sortAndSave()
    }

    func delete(_ domain: LocalDomain) {
        domains.removeAll { $0.id == domain.id }
        save()
    }

    func setEnabled(_ enabled: Bool, for domain: LocalDomain) {
        guard let index = domains.firstIndex(where: { $0.id == domain.id }) else { return }
        domains[index].enabled = enabled
        save()
    }

    func synchronize(with discoveredDomains: [DiscoveredDomain]) {
        let existingByName = Dictionary(
            domains.map { ($0.domain.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var synchronizedDomains = discoveredDomains.map { discovered in
            let discoveredDomain = discovered.localDomain
            guard let existing = existingByName[discovered.domain.lowercased()] else {
                return discoveredDomain
            }

            return LocalDomain(
                id: existing.id,
                domain: discoveredDomain.domain,
                address: discoveredDomain.address,
                wildcard: discoveredDomain.wildcard,
                enabled: discoveredDomain.enabled,
                origin: discoveredDomain.origin
            )
        }

        synchronizedDomains.sort {
            $0.domain.localizedStandardCompare($1.domain) == .orderedAscending
        }

        guard synchronizedDomains != domains else { return }
        domains = synchronizedDomains
        save()
    }

    func containsDomain(named name: String, excluding id: UUID? = nil) -> Bool {
        let normalizedName = name.lowercased()
        return domains.contains {
            $0.id != id && $0.domain.lowercased() == normalizedName
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            domains = try JSONDecoder().decode([LocalDomain].self, from: data)
            domains.sort { $0.domain.localizedStandardCompare($1.domain) == .orderedAscending }
        } catch {
            lastError = String(localized: "Could not load saved domains: \(error.localizedDescription)")
        }
    }

    private func sortAndSave() {
        domains.sort { $0.domain.localizedStandardCompare($1.domain) == .orderedAscending }
        save()
    }

    private func save() {
        guard persistsChanges else { return }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(domains).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = String(localized: "Could not save domains: \(error.localizedDescription)")
        }
    }

    nonisolated private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return applicationSupport
            .appendingPathComponent("Pawxy", isDirectory: true)
            .appendingPathComponent("domains.json", isDirectory: false)
    }
}
