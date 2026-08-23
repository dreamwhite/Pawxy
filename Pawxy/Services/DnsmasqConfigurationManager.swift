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

    var configurationDirectoryPath: String {
        paths.configurationDirectory
    }

    var latestSnapshotDate: Date? {
        ConfigurationSnapshotStore().latest()?.createdAt
    }

    @discardableResult
    func restoreLatestSnapshot() throws -> Date? {
        let store = ConfigurationSnapshotStore()
        guard let snapshot = store.latest() else { return nil }

        var installations: [ConfigurationInstallation] = []
        var deletions: [String] = []
        for entry in snapshot.entries {
            if let data = try store.data(for: entry, snapshot: snapshot) {
                guard let contents = String(data: data, encoding: .utf8) else {
                    throw ManagerError.couldNotRead(entry.destination, "Snapshot is not valid UTF-8")
                }
                installations.append(
                    ConfigurationInstallation(contents: contents, destination: entry.destination)
                )
            } else {
                deletions.append(entry.destination)
            }
        }

        try apply(
            installations: installations,
            deletions: deletions,
            capturesSnapshot: false
        )
        return snapshot.createdAt
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

    var hasManagedConfigurationInclude: Bool {
        guard let contents = try? readConfiguration(at: paths.rootConfiguration) else {
            return false
        }
        return containsManagedConfigurationInclude(contents)
    }

    @discardableResult
    func repairManagedConfigurationInclude() throws -> Bool {
        let currentContents = try readConfiguration(at: paths.rootConfiguration)
        guard !containsManagedConfigurationInclude(currentContents) else { return false }

        var updatedContents = currentContents
        if !updatedContents.isEmpty, !updatedContents.hasSuffix("\n") {
            updatedContents += "\n"
        }
        updatedContents += "\n# Pawxy managed domain configurations\n"
        updatedContents += "conf-dir=\(paths.configurationDirectory),*.conf\n"

        try apply(installations: [
            ConfigurationInstallation(
                contents: updatedContents,
                destination: paths.rootConfiguration
            ),
            ConfigurationInstallation(
                contents: "# Pawxy configuration directory\n",
                destination: "\(paths.configurationDirectory)/pawxy-bootstrap.conf"
            )
        ])
        return true
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
    func ensureSystemResolvers(for domains: [LocalDomain]) throws -> Int {
        var installationsByPath: [String: ConfigurationInstallation] = [:]
        for domain in domains where domain.enabled {
            let changes = try resolverChanges(from: nil, to: domain)
            for installation in changes.installations {
                installationsByPath[installation.destination] = installation
            }
        }
        guard !installationsByPath.isEmpty else { return 0 }
        try apply(
            installations: Array(installationsByPath.values),
            restartDnsmasq: false
        )
        return installationsByPath.count
    }

    @discardableResult
    func add(_ domain: LocalDomain) throws -> LocalDomain {
        try add([domain])[0]
    }

    @discardableResult
    func add(_ domains: [LocalDomain]) throws -> [LocalDomain] {
        guard !domains.isEmpty else { return [] }

        let managedDomains = domains
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
        if case let .conflict(sources) = oldDomain.origin {
            throw ManagerError.conflictingDirectives(oldDomain.domain, sources)
        }
        guard case let .imported(file, line) = oldDomain.origin else {
            return hasSameConfiguration(oldDomain, newDomain) ? oldDomain : try add(newDomain)
        }

        if try isPawxyDomainFile(file) {
            let normalizedDomain = newDomain
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
        if case let .conflict(sources) = domain.origin {
            throw ManagerError.conflictingDirectives(domain.domain, sources)
        }
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
        if case let .conflict(sources) = domain.origin {
            throw ManagerError.conflictingDirectives(domain.domain, sources)
        }
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

        let domains = discovered.map(\.localDomain)
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
        try runPrivilegedRestart()
    }

    func applyPendingChanges(_ changes: [PendingDomainChange]) throws {
        guard !changes.isEmpty else { return }

        var plannedWrites: [String: String] = [:]
        var plannedDeletions = Set<String>()

        func contents(at path: String) throws -> String {
            if let contents = plannedWrites[path] { return contents }
            guard !plannedDeletions.contains(path) else {
                throw ManagerError.directiveNotFound(URL(fileURLWithPath: path).lastPathComponent)
            }
            return try readConfiguration(at: path)
        }

        func stageWrite(_ contents: String, to path: String) {
            plannedDeletions.remove(path)
            plannedWrites[path] = contents
        }

        func stageDeletion(_ path: String) {
            plannedWrites.removeValue(forKey: path)
            plannedDeletions.insert(path)
        }

        func stageResolverChanges(from oldDomain: LocalDomain?, to newDomain: LocalDomain?) throws {
            let changes = try resolverChanges(from: oldDomain, to: newDomain)
            for deletion in changes.deletions {
                stageDeletion(deletion)
            }
            for installation in changes.installations {
                stageWrite(installation.contents, to: installation.destination)
            }
        }

        func ensurePlannedDestinationIsAvailable(_ destination: String, domain: String) throws {
            if plannedDeletions.contains(destination) { return }
            if plannedWrites[destination] != nil {
                throw ManagerError.duplicateDomain(domain)
            }
            try ensureDestinationIsAvailable(destination, domain: domain)
        }

        for change in changes {
            switch change {
            case let .add(domain):
                let destination = configurationFilePath(for: domain.domain)
                try ensurePlannedDestinationIsAvailable(destination, domain: domain.domain)
                stageWrite(DnsmasqConfigurationDocument.managedFile(for: domain), to: destination)
                try stageResolverChanges(from: nil, to: domain)

            case let .update(original, updated):
                if case let .conflict(sources) = original.origin {
                    throw ManagerError.conflictingDirectives(original.domain, sources)
                }
                guard case let .imported(file, line) = original.origin else {
                    let destination = configurationFilePath(for: updated.domain)
                    try ensurePlannedDestinationIsAvailable(destination, domain: updated.domain)
                    stageWrite(DnsmasqConfigurationDocument.managedFile(for: updated), to: destination)
                    try stageResolverChanges(from: original, to: updated)
                    continue
                }

                if try isPawxyDomainFile(file) {
                    let destination = configurationFilePath(for: updated.domain)
                    if standardized(file) != standardized(destination) {
                        try ensurePlannedDestinationIsAvailable(destination, domain: updated.domain)
                        stageDeletion(file)
                    }
                    stageWrite(DnsmasqConfigurationDocument.managedFile(for: updated), to: destination)
                } else {
                    let updatedContents = try DnsmasqConfigurationDocument.replacing(
                        original,
                        nearLine: line,
                        with: updated,
                        in: contents(at: file)
                    )
                    stageWrite(updatedContents, to: file)
                }
                try stageResolverChanges(from: original, to: updated)

            case let .delete(domain):
                if case let .conflict(sources) = domain.origin {
                    throw ManagerError.conflictingDirectives(domain.domain, sources)
                }
                guard case let .imported(file, line) = domain.origin else { continue }

                if try isPawxyDomainFile(file) {
                    stageDeletion(file)
                } else {
                    let updatedContents = try DnsmasqConfigurationDocument.removing(
                        domain,
                        nearLine: line,
                        from: contents(at: file)
                    )
                    if isLegacyManagedFile(file),
                       updatedContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stageDeletion(file)
                    } else {
                        stageWrite(updatedContents, to: file)
                    }
                }
                try stageResolverChanges(from: domain, to: nil)

            case let .resolveConflict(domain, keeping):
                guard case let .conflict(sources) = domain.origin,
                      sources.contains(keeping)
                else {
                    throw ManagerError.directiveNotFound(domain.domain)
                }

                let sourcesToRemove = sources
                    .filter { $0 != keeping }
                    .sorted {
                        if $0.file == $1.file { return $0.line > $1.line }
                        return $0.file.localizedStandardCompare($1.file) == .orderedAscending
                    }

                for source in sourcesToRemove {
                    let sourceDomain = source.domainDefinition(fallback: domain)
                    let updatedContents = try DnsmasqConfigurationDocument.removing(
                        sourceDomain,
                        nearLine: source.line,
                        from: contents(at: source.file)
                    )
                    if try isPawxyDomainFile(source.file),
                       updatedContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stageDeletion(source.file)
                    } else {
                        stageWrite(updatedContents, to: source.file)
                    }
                }

                let resolvedDomain = keeping.domainDefinition(fallback: domain)
                try stageResolverChanges(from: domain, to: resolvedDomain)
            }
        }

        let writesManagedDomainFile = plannedWrites.keys.contains {
            standardized($0).hasPrefix(standardized(paths.configurationDirectory) + "/")
        }
        if writesManagedDomainFile,
           !containsManagedConfigurationInclude(try contents(at: paths.rootConfiguration)) {
            var rootContents = try contents(at: paths.rootConfiguration)
            if !rootContents.isEmpty, !rootContents.hasSuffix("\n") {
                rootContents += "\n"
            }
            rootContents += "\n# Pawxy managed domain configurations\n"
            rootContents += "conf-dir=\(paths.configurationDirectory),*.conf\n"
            stageWrite(rootContents, to: paths.rootConfiguration)
        }

        let installations = plannedWrites.map {
            ConfigurationInstallation(contents: $0.value, destination: $0.key)
        }
        try apply(
            installations: installations,
            deletions: Array(plannedDeletions.subtracting(plannedWrites.keys))
        )
    }

    private func replaceManagedFile(
        _ oldDomain: LocalDomain,
        file oldFile: String,
        newDomain: LocalDomain
    ) throws -> LocalDomain {
        let newDomain = newDomain
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
        let newDomain = newDomain
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

    private func hasSameConfiguration(_ lhs: LocalDomain, _ rhs: LocalDomain) -> Bool {
        lhs.domain == rhs.domain
            && lhs.address == rhs.address
            && lhs.wildcard == rhs.wildcard
            && lhs.enabled == rhs.enabled
    }

    private func containsManagedConfigurationInclude(_ contents: String) -> Bool {
        let expected = standardized(paths.configurationDirectory)
        return contents.components(separatedBy: .newlines).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.hasPrefix("conf-dir=") else { return false }
            let value = String(line.dropFirst("conf-dir=".count))
                .split(separator: ",", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            return standardized(value) == expected
        }
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
        restartDnsmasq: Bool = true,
        capturesSnapshot: Bool = true
    ) throws {
        guard !installations.isEmpty || !deletions.isEmpty else { return }

        do {
            var changes = installations.map {
                AdministratorFileChange.write(
                    destination: $0.destination,
                    contents: Data($0.contents.utf8)
                )
            }
            changes.append(contentsOf: deletions.map(AdministratorFileChange.remove))

            if capturesSnapshot {
                do {
                    _ = try ConfigurationSnapshotStore().capture(
                        paths: Array(Set(changes.map(\.destination)))
                    )
                } catch {
                    throw ManagerError.couldNotBackup(
                        changes.first?.destination ?? "dnsmasq configuration",
                        error.localizedDescription
                    )
                }
            }
            try AdministratorAuthorizationService().transact(
                homebrewPrefix: paths.prefix,
                changes: changes,
                restartDnsmasq: restartDnsmasq
            )
        } catch let error as ManagerError {
            throw error
        } catch let error as AdministratorAuthorizationService.AuthorizationError {
            throw ManagerError.authorizationFailed(error.localizedDescription)
        } catch {
            throw ManagerError.couldNotWrite(
                installations.first?.destination ?? deletions.first ?? "dnsmasq configuration",
                error.localizedDescription
            )
        }
    }

    private func runPrivilegedRestart() throws {
        do {
            try AdministratorAuthorizationService().restartDnsmasq(
                homebrewPrefix: paths.prefix
            )
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
        case conflictingDirectives(String, [DomainDirectiveSource])
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
            case let .conflictingDirectives(domain, sources):
                let sourceList = sources.map(\.label).joined(separator: ", ")
                return String(localized: "Pawxy found conflicting directives for \(domain) in \(sourceList). Resolve the conflict in the source files before editing this domain.")
            case let .legacyConfigurationContainsCustomContent(path):
                return String(localized: "Pawxy did not split \(path) because it contains custom content. The file was left unchanged.")
            case let .couldNotRead(path, detail):
                return String(localized: "Could not read \(path): \(detail)")
            case let .couldNotWrite(path, detail):
                return String(localized: "Could not update \(path): \(detail)")
            case let .couldNotBackup(path, detail):
                return String(localized: "Could not back up \(path): \(detail)")
            case let .authorizationFailed(detail):
                return String(localized: "The administrator operation failed: \(detail)")
            }
        }
    }

    nonisolated private struct Paths {
        let prefix: String

        var configurationDirectory: String { "\(prefix)/etc/dnsmasq.d" }
        var resolverDirectory: String { "/private/etc/resolver" }
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
