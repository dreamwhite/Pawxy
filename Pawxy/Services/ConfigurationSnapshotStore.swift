//
//  ConfigurationSnapshotStore.swift
//  Pawxy
//

import Foundation

nonisolated struct ConfigurationSnapshot: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let destination: String
        let backupFile: String?
    }

    let id: UUID
    let createdAt: Date
    let entries: [Entry]
}

nonisolated struct ConfigurationSnapshotStore {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let maximumSnapshots: Int

    init(
        rootDirectory: URL = ConfigurationSnapshotStore.defaultDirectory,
        fileManager: FileManager = .default,
        maximumSnapshots: Int = 20
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.maximumSnapshots = maximumSnapshots
    }

    func capture(paths: [String]) throws -> ConfigurationSnapshot {
        let id = UUID()
        let directory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var entries: [ConfigurationSnapshot.Entry] = []
        for (index, path) in Array(Set(paths)).sorted().enumerated() {
            let backupName: String?
            if fileManager.fileExists(atPath: path) {
                let name = "\(index)-\(URL(fileURLWithPath: path).lastPathComponent)"
                try fileManager.copyItem(
                    at: URL(fileURLWithPath: path),
                    to: directory.appendingPathComponent(name)
                )
                backupName = name
            } else {
                backupName = nil
            }
            entries.append(.init(destination: path, backupFile: backupName))
        }

        let createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let snapshot = ConfigurationSnapshot(id: id, createdAt: createdAt, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(
            to: directory.appendingPathComponent("snapshot.json"),
            options: .atomic
        )
        prune()
        return snapshot
    }

    func latest() -> ConfigurationSnapshot? {
        snapshots().max { $0.createdAt < $1.createdAt }
    }

    func data(for entry: ConfigurationSnapshot.Entry, snapshot: ConfigurationSnapshot) throws -> Data? {
        guard let backupFile = entry.backupFile else { return nil }
        return try Data(contentsOf: rootDirectory
            .appendingPathComponent(snapshot.id.uuidString, isDirectory: true)
            .appendingPathComponent(backupFile))
    }

    private func snapshots() -> [ConfigurationSnapshot] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("snapshot.json"))
            else { return nil }
            return try? decoder.decode(ConfigurationSnapshot.self, from: data)
        }
    }

    private func prune() {
        let ordered = snapshots().sorted { $0.createdAt > $1.createdAt }
        for snapshot in ordered.dropFirst(maximumSnapshots) {
            try? fileManager.removeItem(
                at: rootDirectory.appendingPathComponent(snapshot.id.uuidString, isDirectory: true)
            )
        }
    }

    nonisolated private static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pawxy", isDirectory: true)
            .appendingPathComponent("Configuration Snapshots", isDirectory: true)
    }
}
