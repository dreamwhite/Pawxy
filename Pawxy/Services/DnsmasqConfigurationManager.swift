//
//  DnsmasqConfigurationManager.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import Foundation

nonisolated struct DnsmasqConfigurationManager {
    private let paths: Paths
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if fileManager.isExecutableFile(atPath: "/opt/homebrew/opt/dnsmasq/sbin/dnsmasq") {
            paths = Paths(prefix: "/opt/homebrew")
        } else {
            paths = Paths(prefix: "/usr/local")
        }
    }

    var rootConfigurationPath: String {
        paths.rootConfiguration
    }

    var hasLegacyManagedConfiguration: Bool {
        guard fileManager.fileExists(atPath: paths.legacyManagedConfiguration),
              let contents = try? String(
                contentsOfFile: paths.legacyManagedConfiguration,
                encoding: .utf8
              )
        else {
            return false
        }

        return contents.components(separatedBy: .newlines).contains {
            $0.trimmingCharacters(in: .whitespaces) == "# Managed by Pawxy"
        }
    }

    func configurationFilePath(for domain: String) -> String {
        let slug = domain
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .joined(separator: "-")
        return "\(paths.configurationDirectory)/\(slug).conf"
    }

    func resolverFilePath(for domain: String) -> String {
        "\(paths.resolverDirectory)/\(domain.lowercased())"
    }

    @discardableResult
    func ensureSystemResolver(for domain: LocalDomain) throws -> Bool {
        guard domain.enabled else { return false }
        let resolverChanges = try resolverChanges(from: nil, to: domain)
        guard !resolverChanges.installations.isEmpty else { return false }
        try apply(
            installations: resolverChanges.installations,
            restartDnsmasq: false
        )
        return true
    }

    @discardableResult
    func add(_ domain: LocalDomain) throws -> LocalDomain {
        try add([domain])[0]
    }

    @discardableResult
    func add(_ domains: [LocalDomain]) throws -> [LocalDomain] {
        guard !domains.isEmpty else { return [] }

        let managedDomains = domains.map(asDnsZone)
        let destinations = managedDomains.map { configurationFilePath(for: $0.domain) }
        guard Set(destinations).count == destinations.count else {
            throw ManagerError.duplicateDomain(managedDomains[0].domain)
        }

        for (domain, destination) in zip(managedDomains, destinations) {
            try ensureDestinationIsAvailable(destination, domain: domain.domain)
        }

        var installations = zip(managedDomains, destinations).map { domain, destination in
            ConfigurationInstallation(
                contents: DnsmasqConfigurationDocument.managedFile(for: domain),
                destination: destination
            )
        }
        for domain in managedDomains {
            let changes = try resolverChanges(from: nil, to: domain)
            installations.append(contentsOf: changes.installations)
        }
        try apply(installations: installations)

        return zip(managedDomains, installations).map { domain, installation in
            managedDomain(
                domain,
                file: installation.destination,
                contents: installation.contents
            )
        }
    }

    @discardableResult
    func update(_ oldDomain: LocalDomain, with newDomain: LocalDomain) throws -> LocalDomain {
        guard case let .imported(file, line) = oldDomain.origin else {
            return hasSameConfiguration(oldDomain, newDomain) ? oldDomain : try add(newDomain)
        }

        if try isPawxyDomainFile(file) {
            let normalizedDomain = asDnsZone(newDomain)
            let expectedContents = DnsmasqConfigurationDocument.managedFile(for: normalizedDomain)
            let expectedPath = configurationFilePath(for: normalizedDomain.domain)
            if standardized(file) == standardized(expectedPath),
               try readConfiguration(at: file) == expectedContents {
                let resolverChanges = try resolverChanges(from: oldDomain, to: normalizedDomain)
                try apply(
                    installations: resolverChanges.installations,
                    deletions: resolverChanges.deletions,
                    restartDnsmasq: false
                )
                return managedDomain(normalizedDomain, file: file, contents: expectedContents)
            }
            return try replaceManagedFile(oldDomain, file: file, newDomain: newDomain)
        }

        if isLegacyManagedFile(file) {
            return try moveLegacyDomainToManagedFile(
                oldDomain,
                nearLine: line,
                newDomain: newDomain,
                legacyFile: file
            )
        }

        let resolverChanges = try resolverChanges(from: oldDomain, to: newDomain)
        guard !hasSameConfiguration(oldDomain, newDomain) else {
            try apply(
                installations: resolverChanges.installations,
                deletions: resolverChanges.deletions,
                restartDnsmasq: false
            )
            return oldDomain
        }

        let currentContents = try readConfiguration(at: file)
        let updatedContents = try DnsmasqConfigurationDocument.replacing(
            oldDomain,
            nearLine: line,
            with: newDomain,
            in: currentContents
        )

        try apply(
            installations: [
                ConfigurationInstallation(contents: updatedContents, destination: file)
            ] + resolverChanges.installations,
            deletions: resolverChanges.deletions
        )
        return managedDomain(newDomain, file: file, contents: updatedContents)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for domain: LocalDomain) throws -> LocalDomain {
        var updatedDomain = domain
        updatedDomain.enabled = enabled

        if enabled == domain.enabled {
            let resolverChanges = try resolverChanges(from: domain, to: updatedDomain)
            try apply(
                installations: resolverChanges.installations,
                deletions: resolverChanges.deletions,
                restartDnsmasq: false
            )
            return domain
        }

        guard case let .imported(file, line) = domain.origin else {
            return enabled ? try add(updatedDomain) : updatedDomain
        }

        if try isPawxyDomainFile(file) {
            return try replaceManagedFile(domain, file: file, newDomain: updatedDomain)
        }

        if isLegacyManagedFile(file) {
            return try moveLegacyDomainToManagedFile(
                domain,
                nearLine: line,
                newDomain: updatedDomain,
                legacyFile: file
            )
        }

        let currentContents = try readConfiguration(at: file)
        let updatedContents = try DnsmasqConfigurationDocument.replacing(
            domain,
            nearLine: line,
            with: updatedDomain,
            in: currentContents
        )

        let resolverChanges = try resolverChanges(from: domain, to: updatedDomain)

        try apply(
            installations: [
                ConfigurationInstallation(contents: updatedContents, destination: file)
            ] + resolverChanges.installations,
            deletions: resolverChanges.deletions
        )
        return managedDomain(updatedDomain, file: file, contents: updatedContents)
    }

    func delete(_ domain: LocalDomain) throws {
        guard case let .imported(file, line) = domain.origin else { return }
        let resolverChanges = try resolverChanges(from: domain, to: nil)

        if try isPawxyDomainFile(file) {
            try apply(deletions: [file] + resolverChanges.deletions)
            return
        }

        let currentContents = try readConfiguration(at: file)
        let updatedContents = try DnsmasqConfigurationDocument.removing(
            domain,
            nearLine: line,
            from: currentContents
        )

        if isLegacyManagedFile(file),
           updatedContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try apply(deletions: [file] + resolverChanges.deletions)
        } else {
            try apply(
                installations: [
                    ConfigurationInstallation(contents: updatedContents, destination: file)
                ],
                deletions: resolverChanges.deletions
            )
        }
    }

    @discardableResult
    func migrateLegacyManagedConfiguration() throws -> Int {
        guard hasLegacyManagedConfiguration else { return 0 }

        let legacyContents = try readConfiguration(at: paths.legacyManagedConfiguration)
        guard DnsmasqConfigurationDocument.isSafeLegacyManagedFile(legacyContents) else {
            throw ManagerError.legacyConfigurationContainsCustomContent(
                paths.legacyManagedConfiguration
            )
        }

        let discovered = DnsmasqConfigScanner(
            rootConfigurationFiles: [paths.legacyManagedConfiguration]
        ).scan()
        guard !discovered.isEmpty else { return 0 }

        let domains = discovered.map(\.localDomain).map(asDnsZone)
        let destinations = domains.map { configurationFilePath(for: $0.domain) }
        for (domain, destination) in zip(domains, destinations) {
            try ensureDestinationIsAvailable(destination, domain: domain.domain)
        }

        var installations = zip(domains, destinations).map { domain, destination in
            ConfigurationInstallation(
                contents: DnsmasqConfigurationDocument.managedFile(for: domain),
                destination: destination
            )
        }
        for domain in domains {
            installations.append(contentsOf: try resolverChanges(from: nil, to: domain).installations)
        }
        try apply(
            installations: installations,
            deletions: [paths.legacyManagedConfiguration]
        )
        return domains.count
    }

    func restart() throws {
        try runPrivileged(.restartDnsmasq(homebrewPrefix: paths.prefix))
    }

    private func replaceManagedFile(
        _ oldDomain: LocalDomain,
        file oldFile: String,
        newDomain: LocalDomain
    ) throws -> LocalDomain {
        let newDomain = asDnsZone(newDomain)
        let destination = configurationFilePath(for: newDomain.domain)
        if standardized(oldFile) != standardized(destination) {
            try ensureDestinationIsAvailable(destination, domain: newDomain.domain)
        }

        let contents = DnsmasqConfigurationDocument.managedFile(for: newDomain)
        let resolverChanges = try resolverChanges(from: oldDomain, to: newDomain)
        try apply(
            installations: [
                ConfigurationInstallation(contents: contents, destination: destination)
            ] + resolverChanges.installations,
            deletions: (standardized(oldFile) == standardized(destination) ? [] : [oldFile])
                + resolverChanges.deletions
        )
        return managedDomain(newDomain, file: destination, contents: contents)
    }

    private func moveLegacyDomainToManagedFile(
        _ oldDomain: LocalDomain,
        nearLine: Int,
        newDomain: LocalDomain,
        legacyFile: String
    ) throws -> LocalDomain {
        let newDomain = asDnsZone(newDomain)
        let destination = configurationFilePath(for: newDomain.domain)
        try ensureDestinationIsAvailable(destination, domain: newDomain.domain)

        let legacyContents = try readConfiguration(at: legacyFile)
        let updatedLegacyContents = try DnsmasqConfigurationDocument.removing(
            oldDomain,
            nearLine: nearLine,
            from: legacyContents
        )
        let managedContents = DnsmasqConfigurationDocument.managedFile(for: newDomain)
        let resolverChanges = try resolverChanges(from: oldDomain, to: newDomain)

        var installations = [
            ConfigurationInstallation(contents: managedContents, destination: destination)
        ] + resolverChanges.installations
        var deletions: [String] = resolverChanges.deletions
        if updatedLegacyContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deletions.append(legacyFile)
        } else {
            installations.append(
                ConfigurationInstallation(
                    contents: updatedLegacyContents,
                    destination: legacyFile
                )
            )
        }

        try apply(installations: installations, deletions: deletions)
        return managedDomain(newDomain, file: destination, contents: managedContents)
    }

    private func ensureDestinationIsAvailable(_ destination: String, domain: String) throws {
        guard fileManager.fileExists(atPath: destination) else { return }

        let contents = try readConfiguration(at: destination)
        if DnsmasqConfigurationDocument.isManagedDomainFile(contents) {
            throw ManagerError.duplicateDomain(domain)
        }
        throw ManagerError.configurationFileExists(destination)
    }

    private func isPawxyDomainFile(_ path: String) throws -> Bool {
        guard standardized(path).hasPrefix(standardized(paths.configurationDirectory) + "/"),
              standardized(path) != standardized(paths.legacyManagedConfiguration)
        else {
            return false
        }

        return DnsmasqConfigurationDocument.isManagedDomainFile(
            try readConfiguration(at: path)
        )
    }

    private func isLegacyManagedFile(_ path: String) -> Bool {
        standardized(path) == standardized(paths.legacyManagedConfiguration)
            && hasLegacyManagedConfiguration
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func readConfiguration(at path: String) throws -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw ManagerError.couldNotRead(path, error.localizedDescription)
        }
    }

    private func managedDomain(_ domain: LocalDomain, file: String, contents: String) -> LocalDomain {
        let line = DnsmasqConfigurationDocument.lineNumber(for: domain, in: contents) ?? 1
        return LocalDomain(
            id: domain.id,
            domain: domain.domain,
            address: domain.address,
            wildcard: domain.wildcard,
            enabled: domain.enabled,
            origin: .imported(file: file, line: line)
        )
    }

    private func asDnsZone(_ domain: LocalDomain) -> LocalDomain {
        var domain = domain
        domain.wildcard = true
        return domain
    }

    private func hasSameConfiguration(_ lhs: LocalDomain, _ rhs: LocalDomain) -> Bool {
        lhs.domain == rhs.domain
            && lhs.address == rhs.address
            && lhs.wildcard == rhs.wildcard
            && lhs.enabled == rhs.enabled
    }

    private func resolverChanges(
        from oldDomain: LocalDomain?,
        to newDomain: LocalDomain?
    ) throws -> ResolverChanges {
        var installations: [ConfigurationInstallation] = []
        var deletions: [String] = []

        if let oldDomain {
            let oldPath = resolverFilePath(for: oldDomain.domain)
            let newPath = newDomain.map { resolverFilePath(for: $0.domain) }
            let keepsSameEnabledResolver = newDomain?.enabled == true
                && newPath.map(standardized) == standardized(oldPath)

            if !keepsSameEnabledResolver,
               fileManager.fileExists(atPath: oldPath),
               MacOSResolverDocument.isManagedFile(try readConfiguration(at: oldPath)) {
                deletions.append(oldPath)
            }
        }

        if let newDomain, newDomain.enabled {
            let path = resolverFilePath(for: newDomain.domain)
            let expectedContents = MacOSResolverDocument.managedFile(for: newDomain.domain)

            if fileManager.fileExists(atPath: path) {
                let contents = try readConfiguration(at: path)
                if MacOSResolverDocument.isManagedFile(contents) {
                    if contents != expectedContents {
                        installations.append(
                            ConfigurationInstallation(
                                contents: expectedContents,
                                destination: path
                            )
                        )
                    }
                } else if !MacOSResolverDocument.routesToLocalDnsmasq(contents) {
                    throw ManagerError.resolverFileExists(path)
                }
            } else {
                installations.append(
                    ConfigurationInstallation(contents: expectedContents, destination: path)
                )
            }
        }

        return ResolverChanges(
            installations: installations,
            deletions: Array(Set(deletions))
        )
    }

    private func apply(
        installations: [ConfigurationInstallation] = [],
        deletions: [String] = [],
        restartDnsmasq: Bool = true
    ) throws {
        guard !installations.isEmpty || !deletions.isEmpty else { return }

        do {
            var changes = installations.map {
                PawxyPrivilegedFileChange.write(
                    destination: $0.destination,
                    contents: Data($0.contents.utf8)
                )
            }
            changes.append(contentsOf: deletions.map(PawxyPrivilegedFileChange.remove))

            for destination in Set(changes.map(\.destination)) {
                try createRecoverableBackup(of: destination)
            }
            try runPrivileged(
                .transact(
                    homebrewPrefix: paths.prefix,
                    changes: changes,
                    restartDnsmasq: restartDnsmasq
                )
            )
        } catch let error as ManagerError {
            throw error
        } catch {
            throw ManagerError.couldNotWrite(
                installations.first?.destination ?? deletions.first ?? "dnsmasq configuration",
                error.localizedDescription
            )
        }
    }

    private func createRecoverableBackup(of path: String) throws {
        guard fileManager.fileExists(atPath: path) else { return }

        let backupDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Pawxy", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)

        do {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let backupName = "\(URL(fileURLWithPath: path).lastPathComponent).\(formatter.string(from: Date())).bak"
            try fileManager.copyItem(
                at: URL(fileURLWithPath: path),
                to: backupDirectory.appendingPathComponent(backupName)
            )
        } catch {
            throw ManagerError.couldNotBackup(path, error.localizedDescription)
        }
    }

    private func runPrivileged(_ operation: PawxyPrivilegedOperation) throws {
        do {
            _ = try PrivilegedHelperClient().perform(operation)
        } catch let error as PrivilegedHelperClient.ClientError {
            throw ManagerError.authorizationFailed(error.localizedDescription)
        } catch {
            throw ManagerError.authorizationFailed(error.localizedDescription)
        }
    }
}

extension DnsmasqConfigurationManager {
    nonisolated enum ManagerError: LocalizedError, Equatable, Sendable {
        case directiveNotFound(String)
        case duplicateDomain(String)
        case configurationFileExists(String)
        case resolverFileExists(String)
        case legacyConfigurationContainsCustomContent(String)
        case couldNotRead(String, String)
        case couldNotWrite(String, String)
        case couldNotBackup(String, String)
        case authorizationFailed(String)

        var errorDescription: String? {
            switch self {
            case let .directiveNotFound(domain):
                return String(localized: "The dnsmasq directive for \(domain) could not be found. Refresh the mappings and try again.")
            case let .duplicateDomain(domain):
                return String(localized: "A dnsmasq directive for \(domain) already exists.")
            case let .configurationFileExists(path):
                return String(localized: "Pawxy cannot create \(path) because that file already exists and is not managed by Pawxy.")
            case let .resolverFileExists(path):
                return String(localized: "Pawxy cannot use \(path) because it already exists and does not route to local dnsmasq. The file was left unchanged.")
            case let .legacyConfigurationContainsCustomContent(path):
                return String(localized: "Pawxy did not split \(path) because it contains custom content. The file was left unchanged.")
            case let .couldNotRead(path, detail):
                return String(localized: "Could not read \(path): \(detail)")
            case let .couldNotWrite(path, detail):
                return String(localized: "Could not update \(path): \(detail)")
            case let .couldNotBackup(path, detail):
                return String(localized: "Could not back up \(path): \(detail)")
            case let .authorizationFailed(detail):
                return String(localized: "The privileged helper operation failed: \(detail)")
            }
        }
    }

    nonisolated private struct Paths {
        let prefix: String

        var configurationDirectory: String { "\(prefix)/etc/dnsmasq.d" }
        var resolverDirectory: String { "/etc/resolver" }
        var legacyManagedConfiguration: String { "\(configurationDirectory)/pawxy.conf" }
        var rootConfiguration: String { "\(prefix)/etc/dnsmasq.conf" }
        var dnsmasqExecutable: String { "\(prefix)/opt/dnsmasq/sbin/dnsmasq" }
    }

    nonisolated private struct ConfigurationInstallation {
        let contents: String
        let destination: String
    }

    nonisolated private struct ResolverChanges {
        let installations: [ConfigurationInstallation]
        let deletions: [String]
    }

}
