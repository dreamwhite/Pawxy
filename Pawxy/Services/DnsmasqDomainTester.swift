//
//  DnsmasqDomainTester.swift
//  Pawxy
//

import Foundation

nonisolated enum DomainResolutionTestResult: Equatable, Sendable {
    case active(hostname: String, address: String)
    case disabled
    case noAnswer(hostname: String)
    case notRouted(hostname: String, expected: String)
    case mdnsConflict(domain: String)
    case mismatch(hostname: String, expected: String, received: [String])
    case failed(String)
}

struct DnsmasqDomainTester {
    private let digPath: String
    private let server: String

    init(digPath: String = "/usr/bin/dig", server: String = "127.0.0.1") {
        self.digPath = digPath
        self.server = server
    }

    func check(_ domain: LocalDomain) async -> DomainResolutionTestResult {
        guard domain.enabled else { return .disabled }

        let hostname = Self.testHostname(
            domain: domain.domain,
            wildcard: domain.wildcard,
            token: UUID().uuidString.lowercased()
        )
        let expectedAddress = domain.address
        let executablePath = digPath
        let dnsServer = server

        return await Task.detached(priority: .userInitiated) {
            let directResult = Self.runDig(
                executablePath: executablePath,
                server: dnsServer,
                hostname: hostname,
                expectedAddress: expectedAddress
            )
            guard case .active = directResult else { return directResult }
            if domain.domain.lowercased().hasSuffix(".local") {
                return .mdnsConflict(domain: domain.domain)
            }
            return Self.runSystemResolver(
                hostname: hostname,
                expectedAddress: expectedAddress
            )
        }.value
    }

    nonisolated static func testHostname(domain: String, wildcard: Bool, token: String) -> String {
        wildcard ? "pawxy-check-\(token).\(domain)" : domain
    }

    nonisolated static func result(
        hostname: String,
        expectedAddress: String,
        output: String,
        terminationStatus: Int32
    ) -> DomainResolutionTestResult {
        guard terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(detail.isEmpty ? String(localized: "dnsmasq did not answer the DNS query.") : detail)
        }

        let addresses = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isIPv4Address)

        if addresses.contains(expectedAddress) {
            return .active(hostname: hostname, address: expectedAddress)
        }
        if addresses.isEmpty {
            return .noAnswer(hostname: hostname)
        }
        return .mismatch(
            hostname: hostname,
            expected: expectedAddress,
            received: addresses
        )
    }

    nonisolated private static func runDig(
        executablePath: String,
        server: String,
        hostname: String,
        expectedAddress: String
    ) -> DomainResolutionTestResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "+short",
            "+time=2",
            "+tries=1",
            "@\(server)",
            hostname,
            "A"
        ]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failed(String(localized: "Could not run the DNS test: \(error.localizedDescription)"))
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return result(
            hostname: hostname,
            expectedAddress: expectedAddress,
            output: output,
            terminationStatus: process.terminationStatus
        )
    }

    nonisolated static func systemResult(
        hostname: String,
        expectedAddress: String,
        output: String,
        terminationStatus: Int32
    ) -> DomainResolutionTestResult {
        guard terminationStatus == 0 else {
            return .notRouted(hostname: hostname, expected: expectedAddress)
        }

        let addresses: [String] = output.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("ip_address:") else { return nil }
            let address = String(line.dropFirst("ip_address:".count))
                .trimmingCharacters(in: .whitespaces)
            return isIPv4Address(address) ? address : nil
        }

        return addresses.contains(expectedAddress)
            ? .active(hostname: hostname, address: expectedAddress)
            : .notRouted(hostname: hostname, expected: expectedAddress)
    }

    nonisolated private static func runSystemResolver(
        hostname: String,
        expectedAddress: String
    ) -> DomainResolutionTestResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-q", "host", "-a", "name", hostname]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failed(String(localized: "Could not query the macOS resolver: \(error.localizedDescription)"))
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return systemResult(
            hostname: hostname,
            expectedAddress: expectedAddress,
            output: output,
            terminationStatus: process.terminationStatus
        )
    }

    nonisolated private static func isIPv4Address(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard let number = Int(component), (0...255).contains(number) else { return false }
            return String(number) == component || component == "0"
        }
    }
}
