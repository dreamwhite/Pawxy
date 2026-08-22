//
//  PawxyTests.swift
//  PawxyTests
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import Foundation
import Testing
@testable import Pawxy

@MainActor
struct PawxyTests {

    @Test func localDomainRoundTripsThroughJSON() throws {
        let domain = LocalDomain(
            domain: "museo.test",
            address: "127.0.0.1",
            wildcard: true,
            origin: .imported(file: "/opt/homebrew/etc/dnsmasq.d/museo.conf", line: 2)
        )

        let encodedDomain = try JSONEncoder().encode(domain)
        let decodedDomain = try JSONDecoder().decode(LocalDomain.self, from: encodedDomain)

        #expect(decodedDomain == domain)
    }

    @Test func validDraftCreatesNormalizedDomain() throws {
        var draft = LocalDomainDraft()
        draft.domain = "  Museo.TEST  "
        draft.address = "127.0.0.1"
        draft.wildcard = true

        let domain = try #require(draft.localDomain)

        #expect(domain.domain == "museo.test")
        #expect(domain.address == "127.0.0.1")
        #expect(domain.wildcard)
    }

    @Test func draftRejectsInvalidIPv4Address() {
        var draft = LocalDomainDraft()
        draft.domain = "museo.test"
        draft.address = "999.0.0.1"

        #expect(draft.localDomain == nil)
        #expect(draft.validationMessage == "Enter a valid IPv4 address.")
    }

    @Test func dependencyCheckerReportsExecutableAvailability() {
        let checker = DependencyChecker(
            homebrewCandidates: ["/usr/bin/true"],
            dnsmasqCandidates: ["/path/that/does/not/exist"]
        )

        let status = checker.check()

        #expect(status.homebrew == .available(at: "/usr/bin/true"))
        #expect(status.dnsmasq == .missing)
        #expect(!status.isReady)
    }

    @Test func dnsmasqScannerFollowsConfigDirectory() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let includedDirectory = temporaryDirectory.appendingPathComponent("dnsmasq.d", isDirectory: true)
        let rootFile = temporaryDirectory.appendingPathComponent("dnsmasq.conf")
        let includedFile = includedDirectory.appendingPathComponent("local.conf")

        try FileManager.default.createDirectory(
            at: includedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try "conf-dir=\(includedDirectory.path),*.conf\n"
            .write(to: rootFile, atomically: true, encoding: .utf8)
        try "address=/.example.test/127.0.0.1\n"
            .write(to: includedFile, atomically: true, encoding: .utf8)

        let domains = DnsmasqConfigScanner(rootConfigurationFiles: [rootFile.path]).scan()
        let domain = try #require(domains.first)

        #expect(domains.count == 1)
        #expect(domain.domain == "example.test")
        #expect(domain.address == "127.0.0.1")
        #expect(domain.wildcard)
        #expect(domain.enabled)
        #expect(domain.sourceFile == includedFile.path)
        #expect(domain.sourceLine == 1)
    }

    @Test func dnsmasqScannerFindsPawxyDisabledMappings() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootFile = temporaryDirectory.appendingPathComponent("dnsmasq.conf")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try "# Pawxy disabled: address=/disabled.test/127.0.0.1\n"
            .write(to: rootFile, atomically: true, encoding: .utf8)

        let domains = DnsmasqConfigScanner(rootConfigurationFiles: [rootFile.path]).scan()
        let domain = try #require(domains.first)

        #expect(domains.count == 1)
        #expect(domain.domain == "disabled.test")
        #expect(!domain.enabled)
        #expect(domain.sourceLine == 1)
    }

    @MainActor
    @Test func domainStorePersistsChangesAsJSON() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = temporaryDirectory.appendingPathComponent("domains.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = DomainStore(fileURL: fileURL)
        store.add(LocalDomain(domain: "example.test", address: "127.0.0.1"))

        let reloadedStore = DomainStore(fileURL: fileURL)

        #expect(reloadedStore.domains.count == 1)
        #expect(reloadedStore.domains.first?.domain == "example.test")
    }

    @MainActor
    @Test func domainStoreSynchronizesFromDnsmasqAsSourceOfTruth() throws {
        let retainedID = UUID()
        let store = DomainStore(
            domains: [
                LocalDomain(
                    id: retainedID,
                    domain: "existing.test",
                    address: "127.0.0.9",
                    origin: .imported(file: "/tmp/old.conf", line: 1)
                ),
                LocalDomain(
                    domain: "stale.test",
                    address: "127.0.0.1",
                    origin: .imported(file: "/tmp/stale.conf", line: 1)
                )
            ],
            persistsChanges: false
        )

        store.synchronize(with: [
            DiscoveredDomain(
                domain: "existing.test",
                address: "127.0.0.2",
                wildcard: true,
                enabled: false,
                sourceFile: "/tmp/current.conf",
                sourceLine: 7
            ),
            DiscoveredDomain(
                domain: "new.test",
                address: "127.0.0.1",
                wildcard: false,
                sourceFile: "/tmp/new.conf",
                sourceLine: 2
            )
        ])

        #expect(store.domains.map(\.domain) == ["existing.test", "new.test"])
        let existing = try #require(store.domains.first)
        #expect(existing.id == retainedID)
        #expect(existing.address == "127.0.0.2")
        #expect(existing.wildcard)
        #expect(!existing.enabled)
        #expect(existing.origin == .imported(file: "/tmp/current.conf", line: 7))
    }

    @Test func dnsmasqDocumentSupportsFullDomainLifecycle() throws {
        let original = LocalDomain(
            domain: "example.test",
            address: "127.0.0.1",
            wildcard: true,
            origin: .imported(file: "/tmp/example.conf", line: 2)
        )

        let added = try DnsmasqConfigurationDocument.adding(original, to: "")
        #expect(added.contains("address=/example.test/127.0.0.1"))

        var disabled = original
        disabled.enabled = false
        let disabledContents = try DnsmasqConfigurationDocument.replacing(
            original,
            nearLine: 2,
            with: disabled,
            in: added
        )
        #expect(disabledContents.contains("# Pawxy disabled: address=/example.test/127.0.0.1"))

        var edited = disabled
        edited.domain = "api.example.test"
        edited.address = "127.0.0.2"
        edited.enabled = true
        let editedContents = try DnsmasqConfigurationDocument.replacing(
            disabled,
            nearLine: 2,
            with: edited,
            in: disabledContents
        )
        #expect(editedContents.contains("address=/api.example.test/127.0.0.2"))

        let removed = try DnsmasqConfigurationDocument.removing(
            edited,
            nearLine: 2,
            from: editedContents
        )
        #expect(!removed.contains("api.example.test"))
        #expect(!removed.contains("Managed by Pawxy"))
    }

    @Test func dnsmasqDocumentPreservesImportedAddressDirectiveStyle() throws {
        let imported = LocalDomain(
            domain: "emporion.local",
            address: "127.0.0.1",
            wildcard: true,
            origin: .imported(file: "/tmp/emporion.conf", line: 2)
        )
        let contents = "# Existing configuration\naddress=/emporion.local/127.0.0.1\n"

        var disabled = imported
        disabled.enabled = false
        let result = try DnsmasqConfigurationDocument.replacing(
            imported,
            nearLine: 2,
            with: disabled,
            in: contents
        )

        #expect(result.contains("# Pawxy disabled: address=/emporion.local/127.0.0.1"))
    }

    @Test func pawxyManagedFilesAreDescriptiveAndDnsmasqCompatible() {
        let exact = LocalDomain(domain: "example.test", address: "127.0.0.1")
        let wildcard = LocalDomain(
            domain: "api.example.test",
            address: "127.0.0.2",
            wildcard: true
        )

        let exactContents = DnsmasqConfigurationDocument.managedFile(for: exact)
        let wildcardContents = DnsmasqConfigurationDocument.managedFile(for: wildcard)

        #expect(exactContents.contains("# Managed by Pawxy. Resolve example.test and its subdomains to 127.0.0.1"))
        #expect(exactContents.contains("address=/example.test/127.0.0.1"))
        #expect(wildcardContents.contains("# Managed by Pawxy. Resolve api.example.test and its subdomains"))
        #expect(wildcardContents.contains("address=/api.example.test/127.0.0.2"))
        #expect(DnsmasqConfigurationDocument.isManagedDomainFile(exactContents))
    }

    @Test func legacySplitRejectsCustomDnsmasqContent() {
        let safeContents = """
        # Managed by Pawxy
        host-record=example.test,127.0.0.1
        # Pawxy disabled: address=/.disabled.test/127.0.0.1
        """
        let customContents = safeContents + "\nserver=1.1.1.1\n"

        #expect(DnsmasqConfigurationDocument.isSafeLegacyManagedFile(safeContents))
        #expect(!DnsmasqConfigurationDocument.isSafeLegacyManagedFile(customContents))
    }

    @Test func pawxyUsesOneReadableConfigurationFilenamePerDomain() {
        let manager = DnsmasqConfigurationManager()
        let path = manager.configurationFilePath(
            for: "API.Example.TEST"
        )

        #expect(path.hasSuffix("/api-example-test.conf"))
        #expect(manager.resolverFilePath(for: "API.Example.TEST") == "/etc/resolver/api.example.test")
    }

    @Test func privilegedHelperRequestRoundTripsThroughJSON() throws {
        let request = PawxyPrivilegedRequest(
            operation: .transact(
                homebrewPrefix: "/opt/homebrew",
                changes: [
                    .write(
                        destination: "/opt/homebrew/etc/dnsmasq.d/example-test.conf",
                        contents: Data("address=/example.test/127.0.0.1\n".utf8)
                    ),
                    .remove(destination: "/etc/resolver/old.example.test")
                ],
                restartDnsmasq: true
            )
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PawxyPrivilegedRequest.self, from: data)

        #expect(decoded == request)
    }

    @Test func privilegedHelperOnlyAllowsDnsmasqAndResolverPaths() throws {
        let policy = try #require(PawxyPrivilegedPathPolicy(prefix: "/opt/homebrew"))

        #expect(policy.allows("/opt/homebrew/etc/dnsmasq.conf"))
        #expect(policy.allows("/opt/homebrew/etc/dnsmasq.d/example-test.conf"))
        #expect(policy.allows("/etc/resolver/example.test"))
        #expect(!policy.allows("/opt/homebrew/etc/unrelated.conf"))
        #expect(!policy.allows("/opt/homebrew/etc/dnsmasq.d/nested/example.conf"))
        #expect(!policy.allows("/etc/resolver/../sudoers"))
        #expect(PawxyPrivilegedPathPolicy(prefix: "/tmp/homebrew") == nil)
    }

    @Test func macOSResolverDocumentRoutesDomainsToLocalDnsmasq() {
        let contents = MacOSResolverDocument.managedFile(for: "indirizzo.pawxy")

        #expect(contents.contains("# Managed by Pawxy. Route indirizzo.pawxy"))
        #expect(contents.contains("nameserver 127.0.0.1"))
        #expect(contents.contains("port 53"))
        #expect(MacOSResolverDocument.isManagedFile(contents))
        #expect(MacOSResolverDocument.routesToLocalDnsmasq(contents))
        #expect(!MacOSResolverDocument.routesToLocalDnsmasq("nameserver 1.1.1.1\n"))
    }

    @Test func dnsmasqDomainTestUsesRandomHostnameForWildcardMappings() {
        #expect(
            DnsmasqDomainTester.testHostname(
                domain: "example.test",
                wildcard: false,
                token: "token"
            ) == "example.test"
        )
        #expect(
            DnsmasqDomainTester.testHostname(
                domain: "example.test",
                wildcard: true,
                token: "token"
            ) == "pawxy-check-token.example.test"
        )
    }

    @Test func dnsmasqDomainTestEvaluatesResolverOutput() {
        #expect(
            DnsmasqDomainTester.result(
                hostname: "example.test",
                expectedAddress: "127.0.0.1",
                output: "127.0.0.1\n",
                terminationStatus: 0
            ) == .active(hostname: "example.test", address: "127.0.0.1")
        )
        #expect(
            DnsmasqDomainTester.result(
                hostname: "example.test",
                expectedAddress: "127.0.0.1",
                output: "127.0.0.2\n",
                terminationStatus: 0
            ) == .mismatch(
                hostname: "example.test",
                expected: "127.0.0.1",
                received: ["127.0.0.2"]
            )
        )
        #expect(
            DnsmasqDomainTester.result(
                hostname: "example.test",
                expectedAddress: "127.0.0.1",
                output: "",
                terminationStatus: 0
            ) == .noAnswer(hostname: "example.test")
        )

        #expect(
            DnsmasqDomainTester.systemResult(
                hostname: "example.test",
                expectedAddress: "127.0.0.1",
                output: "name: example.test\nip_address: 127.0.0.1\n",
                terminationStatus: 0
            ) == .active(hostname: "example.test", address: "127.0.0.1")
        )
        #expect(
            DnsmasqDomainTester.systemResult(
                hostname: "example.test",
                expectedAddress: "127.0.0.1",
                output: "",
                terminationStatus: 0
            ) == .notRouted(hostname: "example.test", expected: "127.0.0.1")
        )
    }

    @Test func portableBackupRoundTripsWithoutSourcePaths() throws {
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let domains = [
            LocalDomain(
                domain: "api.example.test",
                address: "127.0.0.2",
                wildcard: true,
                enabled: false,
                origin: .imported(file: "/opt/homebrew/etc/dnsmasq.d/private.conf", line: 42)
            )
        ]
        let service = PawxyBackupService()

        let data = try service.encodedBackup(for: domains, exportedAt: exportedAt)
        let backup = try service.decodedBackup(from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(backup.formatVersion == 1)
        #expect(backup.exportedAt == exportedAt)
        #expect(backup.mappings.count == 1)
        #expect(backup.mappings.first?.localDomain.domain == "api.example.test")
        #expect(backup.mappings.first?.localDomain.address == "127.0.0.2")
        #expect(backup.mappings.first?.localDomain.wildcard == true)
        #expect(backup.mappings.first?.localDomain.enabled == false)
        #expect(!json.contains("/opt/homebrew"))
        #expect(!json.contains("private.conf"))
    }

    @Test func portableBackupRejectsUnsupportedVersions() throws {
        let json = """
        {
          "formatVersion": 99,
          "exportedAt": "2023-11-14T22:13:20Z",
          "mappings": []
        }
        """

        #expect(throws: PawxyBackupService.BackupError.unsupportedVersion(99)) {
            try PawxyBackupService().decodedBackup(from: Data(json.utf8))
        }
    }

}
