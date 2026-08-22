//
//  LocalDomainDraft.swift
//  Pawxy
//

import Foundation

struct LocalDomainDraft {
    var domain = ""
    var address = "127.0.0.1"
    var wildcard = true
    var enabled = true

    init() {}

    init(domain: LocalDomain) {
        self.domain = domain.domain
        address = domain.address
        wildcard = domain.wildcard
        enabled = domain.enabled
    }

    var normalizedDomain: String {
        domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var validationMessage: String? {
        if normalizedDomain.isEmpty {
            return String(localized: "Enter a domain name.")
        }

        if !isValidDomain {
            return String(localized: "Enter a valid domain, for example my-project.test.")
        }

        if !isValidIPv4Address {
            return String(localized: "Enter a valid IPv4 address.")
        }

        return nil
    }

    var localDomain: LocalDomain? {
        guard validationMessage == nil else { return nil }

        return LocalDomain(
            domain: normalizedDomain,
            address: normalizedAddress,
            wildcard: wildcard,
            enabled: enabled
        )
    }

    func updating(_ domain: LocalDomain) -> LocalDomain? {
        guard validationMessage == nil else { return nil }

        return LocalDomain(
            id: domain.id,
            domain: normalizedDomain,
            address: normalizedAddress,
            wildcard: wildcard,
            enabled: enabled,
            origin: domain.origin
        )
    }

    private var normalizedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidDomain: Bool {
        let labels = normalizedDomain.split(separator: ".", omittingEmptySubsequences: false)

        return labels.count >= 2 && labels.allSatisfy { label in
            guard let first = label.first, let last = label.last else { return false }
            guard first.isLetter || first.isNumber else { return false }
            guard last.isLetter || last.isNumber else { return false }

            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private var isValidIPv4Address: Bool {
        let octets = normalizedAddress.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }

        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                  octet.allSatisfy(\.isNumber),
                  let value = Int(octet)
            else {
                return false
            }

            return (0...255).contains(value)
        }
    }
}
