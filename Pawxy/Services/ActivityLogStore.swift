//
//  ActivityLogStore.swift
//  Pawxy
//

import Combine
import Foundation

@MainActor
final class ActivityLogStore: ObservableObject {
    @Published private(set) var entries: [ActivityLogEntry] = []

    private let fileURL: URL
    private let maximumEntries: Int

    init(
        fileURL: URL = ActivityLogStore.defaultFileURL,
        maximumEntries: Int = 200
    ) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
        load()
    }

    func record(
        _ kind: ActivityLogEntry.Kind,
        title: String,
        detail: String = "",
        succeeded: Bool = true
    ) {
        entries.insert(
            ActivityLogEntry(
                kind: kind,
                title: title,
                detail: detail,
                succeeded: succeeded
            ),
            at: 0
        )
        if entries.count > maximumEntries {
            entries.removeLast(entries.count - maximumEntries)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([ActivityLogEntry].self, from: data)
        else { return }
        entries = Array(decoded.prefix(maximumEntries))
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // Logging must never interrupt DNS management.
        }
    }

    nonisolated private static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pawxy", isDirectory: true)
            .appendingPathComponent("activity-log.json", isDirectory: false)
    }
}
