//
//  DomainHealthCheckService.swift
//  Pawxy
//

import Foundation

nonisolated struct DomainHealthCheckService: Sendable {
    let maximumConcurrentChecks: Int

    init(maximumConcurrentChecks: Int = 4) {
        self.maximumConcurrentChecks = max(1, maximumConcurrentChecks)
    }

    func check(_ domains: [LocalDomain]) async -> [UUID: DomainResolutionTestResult] {
        let domains = domains.filter {
            if case .conflict = $0.origin { return false }
            return true
        }
        var results: [UUID: DomainResolutionTestResult] = [:]

        for start in stride(from: 0, to: domains.count, by: maximumConcurrentChecks) {
            guard !Task.isCancelled else { break }
            let end = min(start + maximumConcurrentChecks, domains.count)
            let batch = Array(domains[start..<end])

            await withTaskGroup(of: (UUID, DomainResolutionTestResult).self) { group in
                for domain in batch {
                    group.addTask {
                        (domain.id, await DnsmasqDomainTester().check(domain))
                    }
                }
                for await (id, result) in group {
                    results[id] = result
                }
            }
        }

        return results
    }
}
