//
//  DnsmasqConfigurationWatcher.swift
//  Pawxy
//

import Combine
import Foundation

@MainActor
final class DnsmasqConfigurationWatcher: ObservableObject {
    private var task: Task<Void, Never>?

    func start(paths: [String], onChange: @escaping @MainActor () -> Void) {
        stop()
        task = Task {
            var previous = await Self.fingerprint(paths: paths)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                let current = await Self.fingerprint(paths: paths)
                guard current != previous else { continue }
                previous = current
                onChange()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private nonisolated static func fingerprint(paths: [String]) async -> String {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var components: [String] = []

            for path in paths.sorted() {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    components.append("\(path)|missing")
                    continue
                }

                let files: [String]
                if isDirectory.boolValue {
                    files = (try? fileManager.contentsOfDirectory(atPath: path))?
                        .filter { !$0.hasPrefix(".") }
                        .map { URL(fileURLWithPath: path).appendingPathComponent($0).path }
                        .sorted() ?? []
                } else {
                    files = [path]
                }

                for file in files {
                    let attributes = try? fileManager.attributesOfItem(atPath: file)
                    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let size = attributes?[.size] as? NSNumber ?? 0
                    components.append("\(file)|\(modified)|\(size)")
                }
            }
            return components.joined(separator: "\n")
        }.value
    }
}
