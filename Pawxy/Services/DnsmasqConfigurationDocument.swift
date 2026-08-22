//
//  DnsmasqConfigurationDocument.swift
//  Pawxy
//

import Foundation

nonisolated enum DnsmasqConfigurationDocument {
    private static let disabledPrefix = "# Pawxy disabled: "
    private static let managedComment = "# Managed by Pawxy"

    static func managedFile(for domain: LocalDomain) -> String {
        let description = "Resolve \(domain.domain) and its subdomains to \(domain.address) for local development."
        let directive = addressDirective(for: domain)
        let renderedDirective = domain.enabled ? directive : disabledPrefix + directive
        return "\(managedComment). \(description)\n\(renderedDirective)\n"
    }

    static func isManagedDomainFile(_ contents: String) -> Bool {
        contents.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
            .hasPrefix("\(managedComment).") == true
    }

    static func isSafeLegacyManagedFile(_ contents: String) -> Bool {
        let meaningfulLines = contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard meaningfulLines.contains(managedComment) else { return false }

        return meaningfulLines.allSatisfy { line in
            line == managedComment
                || line.hasPrefix("address=")
                || line.hasPrefix("host-record=")
                || line.hasPrefix(disabledPrefix + "address=")
                || line.hasPrefix(disabledPrefix + "host-record=")
        }
    }

    static func adding(_ domain: LocalDomain, to contents: String) throws -> String {
        if lineNumber(for: domain, in: contents) != nil {
            throw DnsmasqConfigurationManager.ManagerError.duplicateDomain(domain.domain)
        }

        var updated = contents
        if !updated.isEmpty, !updated.hasSuffix("\n") {
            updated += "\n"
        }
        if !updated.isEmpty {
            updated += "\n"
        }
        updated += "\(managedComment)\n\(render(domain))\n"
        return updated
    }

    static func replacing(
        _ oldDomain: LocalDomain,
        nearLine: Int,
        with newDomain: LocalDomain,
        in contents: String
    ) throws -> String {
        var lines = contents.components(separatedBy: .newlines)
        guard let index = matchingLineIndex(for: oldDomain, nearLine: nearLine, in: lines) else {
            throw DnsmasqConfigurationManager.ManagerError.directiveNotFound(oldDomain.domain)
        }

        let oldDirective = uncommentedDirective(lines[index])
        let preservesAddressStyle = oldDomain.wildcard == newDomain.wildcard
            && oldDirective.hasPrefix("address=")
        let preservesHostRecordStyle = oldDomain.wildcard == newDomain.wildcard
            && oldDirective.hasPrefix("host-record=")

        let directive: String
        if preservesAddressStyle {
            directive = addressDirective(for: newDomain)
        } else if preservesHostRecordStyle {
            directive = hostRecordDirective(for: newDomain)
        } else {
            directive = baseDirective(for: newDomain)
        }

        lines[index] = newDomain.enabled ? directive : disabledPrefix + directive
        return lines.joined(separator: "\n")
    }

    static func removing(
        _ domain: LocalDomain,
        nearLine: Int,
        from contents: String
    ) throws -> String {
        var lines = contents.components(separatedBy: .newlines)
        guard let index = matchingLineIndex(for: domain, nearLine: nearLine, in: lines) else {
            throw DnsmasqConfigurationManager.ManagerError.directiveNotFound(domain.domain)
        }

        lines.remove(at: index)
        if index > 0, lines[index - 1].trimmingCharacters(in: .whitespaces) == managedComment {
            lines.remove(at: index - 1)
        }

        while lines.count > 1,
              lines.last?.isEmpty == true,
              lines[lines.count - 2].isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    static func lineNumber(for domain: LocalDomain, in contents: String) -> Int? {
        let lines = contents.components(separatedBy: .newlines)
        return matchingLineIndex(for: domain, nearLine: nil, in: lines).map { $0 + 1 }
    }

    private static func matchingLineIndex(
        for domain: LocalDomain,
        nearLine: Int?,
        in lines: [String]
    ) -> Int? {
        if let nearLine {
            let index = nearLine - 1
            if lines.indices.contains(index), matches(lines[index], domain: domain) {
                return index
            }
        }

        return lines.firstIndex { matches($0, domain: domain) }
    }

    private static func matches(_ line: String, domain: LocalDomain) -> Bool {
        let directive = uncommentedDirective(line)
        let normalizedDomain = domain.domain.lowercased()

        if directive.hasPrefix("address=") {
            let value = String(directive.dropFirst("address=".count))
            let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts.last == domain.address else { return false }
            return parts.dropFirst().dropLast().contains {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == normalizedDomain
            }
        }

        if directive.hasPrefix("host-record=") {
            let parts = directive
                .dropFirst("host-record=".count)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.first?.lowercased() == normalizedDomain && parts.contains(domain.address)
        }

        return false
    }

    private static func render(_ domain: LocalDomain) -> String {
        let directive = baseDirective(for: domain)
        return domain.enabled ? directive : disabledPrefix + directive
    }

    private static func baseDirective(for domain: LocalDomain) -> String {
        domain.wildcard ? addressDirective(for: domain) : hostRecordDirective(for: domain)
    }

    private static func addressDirective(for domain: LocalDomain) -> String {
        "address=/\(domain.domain)/\(domain.address)"
    }

    private static func hostRecordDirective(for domain: LocalDomain) -> String {
        "host-record=\(domain.domain),\(domain.address)"
    }

    private static func uncommentedDirective(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(disabledPrefix) {
            return String(trimmed.dropFirst(disabledPrefix.count))
        }
        return trimmed
    }
}
