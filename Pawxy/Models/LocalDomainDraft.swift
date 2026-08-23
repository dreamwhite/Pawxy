//
//  LocalDomainDraft.swift
//  Pawxy
//

import Foundation

struct LocalDomainDraft {
    enum AddressFamily: Equatable {
        case ipv4
        case ipv6
    }

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

    var addressFamily: AddressFamily? {
        guard let address = normalizedIPAddress else { return nil }
        return IPAddress.isIPv6(address) ? .ipv6 : .ipv4
    }

    var validationMessage: String? {
        if normalizedDomain.isEmpty {
            return String(localized: "Enter a domain name.")
        }

        if !isValidDomain {
            return String(localized: "Enter a valid domain, for example my-project.test.")
        }

        if normalizedDomain == "local" || normalizedDomain.hasSuffix(".local") {
            return String(localized: "The .local suffix is reserved by macOS for Bonjour. Use .test or another development suffix.")
        }

        if normalizedIPAddress == nil {
            return String(localized: "Enter a valid IPv4 or IPv6 address.")
        }

        return nil
    }

    var localDomain: LocalDomain? {
        guard validationMessage == nil else { return nil }

        return LocalDomain(
            domain: normalizedDomain,
            address: normalizedIPAddress ?? normalizedAddress,
            wildcard: wildcard,
            enabled: enabled
        )
    }

    func updating(_ domain: LocalDomain) -> LocalDomain? {
        guard validationMessage == nil else { return nil }

        return LocalDomain(
            id: domain.id,
            domain: normalizedDomain,
            address: normalizedIPAddress ?? normalizedAddress,
            wildcard: wildcard,
            enabled: enabled,
            origin: domain.origin
        )
    }

    private var normalizedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidDomain: Bool {
        guard normalizedDomain.utf8.count <= 253,
              normalizedDomain.unicodeScalars.allSatisfy({ $0.isASCII })
        else {
            return false
        }

        let labels = normalizedDomain.split(separator: ".", omittingEmptySubsequences: false)

        return labels.count >= 2 && labels.allSatisfy { label in
            guard label.utf8.count <= 63 else { return false }
            guard let first = label.first, let last = label.last else { return false }
            guard first.isASCII && (first.isLetter || first.isNumber) else { return false }
            guard last.isASCII && (last.isLetter || last.isNumber) else { return false }

            return label.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
            }
        }
    }

    private var normalizedIPAddress: String? {
        IPAddress.normalized(normalizedAddress)
    }
}
