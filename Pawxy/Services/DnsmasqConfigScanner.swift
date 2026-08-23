//
//  DnsmasqConfigScanner.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import Foundation

nonisolated struct DnsmasqConfigScanner {
    private let rootConfigurationFiles: [String]
    private let fileManager: FileManager

    init(
        rootConfigurationFiles: [String] = [
            "/opt/homebrew/etc/dnsmasq.conf",
            "/usr/local/etc/dnsmasq.conf"
        ],
        fileManager: FileManager = .default
    ) {
        self.rootConfigurationFiles = rootConfigurationFiles
        self.fileManager = fileManager
    }

    func scan() -> [DiscoveredDomain] {
        var pendingFiles = rootConfigurationFiles.filter(fileManager.fileExists(atPath:))
        var visitedFiles = Set<String>()
        var results: [DiscoveredDomain] = []

        while let path = pendingFiles.popLast() {
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard visitedFiles.insert(standardizedPath).inserted,
                  let contents = try? String(contentsOfFile: standardizedPath, encoding: .utf8)
            else {
                continue
            }

            for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
                let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }

                let disabledPrefix = "# Pawxy disabled: "
                let enabled = !trimmedLine.hasPrefix(disabledPrefix)
                let line: String

                if enabled {
                    guard !trimmedLine.hasPrefix("#") else { continue }
                    line = trimmedLine
                } else {
                    line = String(trimmedLine.dropFirst(disabledPrefix.count))
                        .trimmingCharacters(in: .whitespaces)
                }

                if let includedFile = value(after: "conf-file=", in: line) {
                    pendingFiles.append(expandPath(includedFile))
                    continue
                }

                if let directoryValue = value(after: "conf-dir=", in: line) {
                    pendingFiles.append(contentsOf: files(inDirectoryDirective: directoryValue))
                    continue
                }

                if let addressValue = value(after: "address=", in: line) {
                    results.append(contentsOf: parseAddressDirective(
                        addressValue,
                        enabled: enabled,
                        sourceFile: standardizedPath,
                        sourceLine: offset + 1
                    ))
                    continue
                }

                if let hostRecordValue = value(after: "host-record=", in: line),
                   let hostRecord = parseHostRecordDirective(
                    hostRecordValue,
                    enabled: enabled,
                    sourceFile: standardizedPath,
                    sourceLine: offset + 1
                   ) {
                    results.append(hostRecord)
                }
            }
        }

        return Dictionary(grouping: results, by: { $0.domain.lowercased() })
            .values
            .compactMap { matches -> DiscoveredDomain? in
                let ordered = matches.sorted {
                    if $0.sourceFile == $1.sourceFile {
                        return $0.sourceLine < $1.sourceLine
                    }
                    return $0.sourceFile.localizedStandardCompare($1.sourceFile) == .orderedAscending
                }
                guard let preferred = ordered.first else { return nil }
                guard ordered.count > 1 else { return preferred }

                return DiscoveredDomain(
                    id: preferred.id,
                    domain: preferred.domain,
                    address: preferred.address,
                    wildcard: preferred.wildcard,
                    enabled: preferred.enabled,
                    sourceFile: preferred.sourceFile,
                    sourceLine: preferred.sourceLine,
                    conflictingSources: ordered.map {
                        DomainDirectiveSource(
                            file: $0.sourceFile,
                            line: $0.sourceLine,
                            address: $0.address,
                            wildcard: $0.wildcard,
                            enabled: $0.enabled
                        )
                    }
                )
            }
            .sorted { $0.domain.localizedStandardCompare($1.domain) == .orderedAscending }
    }

    private func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func parseAddressDirective(
        _ value: String,
        enabled: Bool,
        sourceFile: String,
        sourceLine: Int
    ) -> [DiscoveredDomain] {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let address = parts.last.map(String.init),
              IPAddress.normalized(address) != nil
        else {
            return []
        }

        let normalizedAddress = IPAddress.normalized(address) ?? address
        return parts.dropFirst().dropLast().compactMap { rawDomain in
            var domain = String(rawDomain).trimmingCharacters(in: .whitespaces)
            guard !domain.isEmpty, domain != "#" else { return nil }

            if domain.hasPrefix(".") {
                domain.removeFirst()
            }

            return DiscoveredDomain(
                domain: domain.lowercased(),
                address: normalizedAddress,
                wildcard: true,
                enabled: enabled,
                sourceFile: sourceFile,
                sourceLine: sourceLine
            )
        }
    }

    private func parseHostRecordDirective(
        _ value: String,
        enabled: Bool,
        sourceFile: String,
        sourceLine: Int
    ) -> DiscoveredDomain? {
        let parts = value.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }

        guard let addressIndex = parts.firstIndex(where: { IPAddress.normalized($0) != nil }),
              addressIndex > 0 else {
            return nil
        }

        let domain = parts[0].lowercased()
        guard domain.contains(".") else { return nil }

        return DiscoveredDomain(
            domain: domain,
            address: IPAddress.normalized(parts[addressIndex]) ?? parts[addressIndex],
            wildcard: false,
            enabled: enabled,
            sourceFile: sourceFile,
            sourceLine: sourceLine
        )
    }

    private func files(inDirectoryDirective value: String) -> [String] {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let rawDirectory = parts.first else { return [] }

        let directory = expandPath(rawDirectory)
        let filter = parts.dropFirst().first

        guard let files = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }

        return files.compactMap { filename in
            guard !filename.hasPrefix(".") else { return nil }

            if let filter, !filter.isEmpty {
                if filter.hasPrefix("*"), !filename.hasSuffix(String(filter.dropFirst())) {
                    return nil
                }

                if filter.hasPrefix("."), filename.hasSuffix(filter) {
                    return nil
                }
            }

            let path = URL(fileURLWithPath: directory).appendingPathComponent(filename).path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return nil
            }

            return path
        }
    }

    private func expandPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

}
