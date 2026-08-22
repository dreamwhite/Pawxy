//
//  MacOSResolverDocument.swift
//  Pawxy
//

import Foundation

nonisolated enum MacOSResolverDocument {
    private static let managedComment = "# Managed by Pawxy"

    static func managedFile(for domain: String) -> String {
        """
        \(managedComment). Route \(domain) and its subdomains to local dnsmasq.
        nameserver 127.0.0.1
        port 53

        """
    }

    static func isManagedFile(_ contents: String) -> Bool {
        contents.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
            .hasPrefix("\(managedComment).") == true
    }

    static func routesToLocalDnsmasq(_ contents: String) -> Bool {
        var nameserver: String?
        var port: String?

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { continue }
            if fields[0] == "nameserver" {
                nameserver = fields[1]
            } else if fields[0] == "port" {
                port = fields[1]
            }
        }

        return nameserver == "127.0.0.1" && (port == nil || port == "53")
    }
}
