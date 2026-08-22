//
//  LocalDomain+Mocks.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

extension LocalDomain {
    static let mockDomains = [
        LocalDomain(domain: "indirizzo.pawxy", address: "127.0.0.1", wildcard: true),
        LocalDomain(domain: "api.indirizzo.pawxy", address: "127.0.0.1"),
        LocalDomain(domain: "shop.test", address: "192.168.1.50", enabled: false)
    ]
}
