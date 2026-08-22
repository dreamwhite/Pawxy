//
//  ContentView.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: DomainStore
    @EnvironmentObject private var helperController: PrivilegedHelperController

    @State private var environmentStatus: DevelopmentEnvironmentStatus
    private let dnsmasqManager = DnsmasqConfigurationManager()

    @AppStorage("defaultIPv4Address") private var defaultIPv4Address = "127.0.0.1"

    @State private var destination: SidebarDestination? = .domains
    @State private var searchText = ""
    @State private var discoveredDomains: [DiscoveredDomain] = []
    @State private var hasLegacyConfiguration = false
    @State private var editorPresentation: DomainEditorPresentation?
    @State private var backupImportPresentation: BackupImportPresentation?
    @State private var deletionCandidate: LocalDomain?
    @State private var serviceMessage: String?
    @State private var configurationError: String?
    @State private var updatingDomainIDs = Set<UUID>()
    @State private var healthCheckRevision = 0
    @State private var isPerformingServiceOperation = false

    init(environmentStatus: DevelopmentEnvironmentStatus) {
        _environmentStatus = State(initialValue: environmentStatus)
    }

    var body: some View {
        NavigationSplitView {
            PawxySidebar(
                destination: $destination,
                environmentStatus: environmentStatus
            )
        } detail: {
            detail
        }
        .frame(minWidth: 940, minHeight: 620)
        .sheet(item: $editorPresentation, content: domainEditor)
        .sheet(item: $backupImportPresentation, content: backupImportSheet)
        .confirmationDialog(
            "Delete \(deletionCandidate?.domain ?? "domain")?",
            isPresented: deletionBinding
        ) {
            Button("Delete", role: .destructive, action: deleteSelectedDomain)
            Button("Cancel", role: .cancel) {
                deletionCandidate = nil
            }
        } message: {
            if case .imported = deletionCandidate?.origin {
                Text("This removes the directive from its dnsmasq configuration file through Pawxy’s privileged helper and restarts the service.")
            } else {
                Text("This action cannot be undone.")
            }
        }
        .alert("dnsmasq", isPresented: serviceMessageBinding) {
            Button("OK") { serviceMessage = nil }
        } message: {
            Text(serviceMessage ?? "")
        }
        .alert("dnsmasq operation failed", isPresented: configurationErrorBinding) {
            Button("OK") { configurationError = nil }
        } message: {
            Text(configurationError ?? "")
        }
        .task {
            refreshMappings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addPawxyDomain)) { _ in
            showDomainEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshPawxyMappings)) { _ in
            refreshMappings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .restartPawxyDnsmasq)) { _ in
            restartDnsmasq()
        }
        .onReceive(NotificationCenter.default.publisher(for: .importPawxyBackup)) { _ in
            chooseBackupToImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportPawxyBackup)) { _ in
            exportBackup()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch destination ?? .domains {
        case .overview:
            OverviewView(
                domains: store.domains,
                environmentStatus: environmentStatus,
                onShowDomains: { destination = .domains },
                onAddDomain: showDomainEditor,
                onRefresh: refreshMappings,
                onRestart: restartDnsmasq,
                onRevealFile: revealFile,
                onShowEnvironment: { destination = .environment }
            )

        case .domains:
            DomainsView(
                store: store,
                searchText: $searchText,
                updatingDomainIDs: updatingDomainIDs,
                healthCheckRevision: healthCheckRevision,
                onAdd: showDomainEditor,
                onRefresh: refreshMappings,
                onImportBackup: chooseBackupToImport,
                onExportBackup: exportBackup,
                onShowInFinder: revealSourceFile,
                onRepairResolver: repairSystemResolver,
                onEdit: editDomain,
                onDelete: requestDeletion,
                onSetEnabled: setDomainEnabled
            )

        case .environment:
            EnvironmentView(
                status: environmentStatus,
                discoveredDomainCount: discoveredDomains.count,
                showsLegacyConfiguration: hasLegacyConfiguration,
                onCheckAgain: {
                    environmentStatus = DependencyChecker().check()
                },
                onRefresh: refreshMappings,
                onRestart: restartDnsmasq,
                onMigrateLegacy: migrateLegacyConfiguration,
                onShowConfiguration: {
                    revealFile(dnsmasqManager.rootConfigurationPath)
                }
            )
        }
    }

    private func domainEditor(_ presentation: DomainEditorPresentation) -> some View {
        DomainEditorView(
            domain: presentation.domain,
            existingDomains: store.domains,
            defaultAddress: defaultIPv4Address
        ) { domain in
            guard requirePrivilegedHelper() else {
                throw DnsmasqConfigurationManager.ManagerError.authorizationFailed(
                    helperController.state.detail
                )
            }
            if let existingDomain = presentation.domain {
                let managedDomain = try await Task.detached {
                    try DnsmasqConfigurationManager().update(existingDomain, with: domain)
                }.value
                store.update(managedDomain)
            } else {
                let managedDomain = try await Task.detached {
                    try DnsmasqConfigurationManager().add(domain)
                }.value
                store.add(managedDomain)
            }
            refreshMappings()
        }
    }

    private func backupImportSheet(_ presentation: BackupImportPresentation) -> some View {
        BackupImportView(
            backup: presentation.backup,
            filename: presentation.filename,
            existingDomainNames: Set(store.domains.map { $0.domain.lowercased() })
        ) { domains in
            guard requirePrivilegedHelper() else {
                throw DnsmasqConfigurationManager.ManagerError.authorizationFailed(
                    helperController.state.detail
                )
            }
            let currentNames = Set(
                DnsmasqConfigScanner().scan().map { $0.domain.lowercased() }
            )
            if let conflict = domains.first(where: {
                currentNames.contains($0.domain.lowercased())
            }) {
                throw DnsmasqConfigurationManager.ManagerError.duplicateDomain(conflict.domain)
            }

            _ = try await Task.detached {
                try DnsmasqConfigurationManager().add(domains)
            }.value
            refreshMappings()
            serviceMessage = domains.count == 1
                ? String(localized: "Imported one mapping and restarted dnsmasq.")
                : String(localized: "Imported \(domains.count) mappings and restarted dnsmasq.")
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { deletionCandidate != nil },
            set: { if !$0 { deletionCandidate = nil } }
        )
    }

    private var serviceMessageBinding: Binding<Bool> {
        Binding(
            get: { serviceMessage != nil },
            set: { if !$0 { serviceMessage = nil } }
        )
    }

    private var configurationErrorBinding: Binding<Bool> {
        Binding(
            get: { configurationError != nil },
            set: { if !$0 { configurationError = nil } }
        )
    }

    private func showDomainEditor() {
        guard requirePrivilegedHelper() else { return }
        destination = .domains
        editorPresentation = .add
    }

    private func editDomain(_ domain: LocalDomain) {
        guard requirePrivilegedHelper() else { return }
        editorPresentation = .edit(domain)
    }

    private func requestDeletion(_ domain: LocalDomain) {
        guard requirePrivilegedHelper() else { return }
        deletionCandidate = domain
    }

    private func refreshMappings() {
        discoveredDomains = DnsmasqConfigScanner().scan()
        store.synchronize(with: discoveredDomains)
        hasLegacyConfiguration = dnsmasqManager.hasLegacyManagedConfiguration
        healthCheckRevision &+= 1
    }

    private func restartDnsmasq() {
        guard requirePrivilegedHelper() else { return }
        guard !isPerformingServiceOperation else { return }
        isPerformingServiceOperation = true
        Task {
            defer { isPerformingServiceOperation = false }
            do {
                try await Task.detached {
                    try DnsmasqConfigurationManager().restart()
                }.value
                refreshMappings()
                serviceMessage = String(localized: "The configuration is valid and dnsmasq was restarted successfully.")
            } catch {
                configurationError = error.localizedDescription
            }
        }
    }

    private func migrateLegacyConfiguration() {
        guard requirePrivilegedHelper() else { return }
        guard !isPerformingServiceOperation else { return }
        isPerformingServiceOperation = true
        Task {
            defer { isPerformingServiceOperation = false }
            do {
                let count = try await Task.detached {
                    try DnsmasqConfigurationManager().migrateLegacyManagedConfiguration()
                }.value
                refreshMappings()
                serviceMessage = count == 0
                    ? String(localized: "No legacy Pawxy mappings needed migration.")
                    : count == 1
                        ? String(localized: "Moved one mapping into a separate dnsmasq configuration file.")
                        : String(localized: "Moved \(count) mappings into separate dnsmasq configuration files.")
            } catch {
                configurationError = error.localizedDescription
            }
        }
    }

    private func revealSourceFile(for domain: LocalDomain) {
        guard case let .imported(file, _) = domain.origin else { return }
        revealFile(file)
    }

    private func revealFile(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            configurationError = String(localized: "The configuration file no longer exists at \(path). Refresh the mappings and try again.")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func chooseBackupToImport() {
        guard requirePrivilegedHelper() else { return }
        refreshMappings()

        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Pawxy Backup")
        panel.message = String(localized: "Choose a Pawxy JSON backup to review before importing.")
        panel.prompt = String(localized: "Review Backup")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let backup = try PawxyBackupService().read(from: url)
            backupImportPresentation = BackupImportPresentation(
                backup: backup,
                filename: url.lastPathComponent
            )
        } catch {
            configurationError = error.localizedDescription
        }
    }

    private func exportBackup() {
        refreshMappings()

        let panel = NSSavePanel()
        panel.title = String(localized: "Export Pawxy Backup")
        panel.message = String(localized: "Save a portable copy of your current domain mappings.")
        panel.prompt = String(localized: "Export")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultBackupFilename

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try PawxyBackupService().export(store.domains, to: url)
            serviceMessage = store.domains.count == 1
                ? String(localized: "Exported one mapping to \(url.lastPathComponent).")
                : String(localized: "Exported \(store.domains.count) mappings to \(url.lastPathComponent).")
        } catch {
            configurationError = error.localizedDescription
        }
    }

    private var defaultBackupFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        return String(localized: "Pawxy Backup \(date).pawxy.json")
    }

    private func setDomainEnabled(_ enabled: Bool, domain: LocalDomain) {
        guard requirePrivilegedHelper() else { return }
        guard !updatingDomainIDs.contains(domain.id),
              store.domains.first(where: { $0.id == domain.id })?.enabled != enabled
        else {
            return
        }

        updatingDomainIDs.insert(domain.id)
        Task {
            defer { updatingDomainIDs.remove(domain.id) }
            do {
                let managedDomain = try await Task.detached {
                    try DnsmasqConfigurationManager().setEnabled(enabled, for: domain)
                }.value
                store.update(managedDomain)
                refreshMappings()
            } catch {
                configurationError = error.localizedDescription
            }
        }
    }

    private func repairSystemResolver(for domain: LocalDomain) {
        guard requirePrivilegedHelper() else { return }
        guard !updatingDomainIDs.contains(domain.id) else { return }

        updatingDomainIDs.insert(domain.id)
        Task {
            defer { updatingDomainIDs.remove(domain.id) }
            do {
                let installed = try await Task.detached {
                    try DnsmasqConfigurationManager().ensureSystemResolver(for: domain)
                }.value
                serviceMessage = installed
                    ? "Installed the macOS resolver for \(domain.domain)."
                    : "The macOS resolver for \(domain.domain) is already configured correctly."
                healthCheckRevision &+= 1
            } catch {
                configurationError = error.localizedDescription
            }
        }
    }

    private func deleteSelectedDomain() {
        guard requirePrivilegedHelper() else {
            deletionCandidate = nil
            return
        }
        guard let deletionCandidate else { return }
        self.deletionCandidate = nil
        guard !updatingDomainIDs.contains(deletionCandidate.id) else { return }
        updatingDomainIDs.insert(deletionCandidate.id)
        Task {
            defer { updatingDomainIDs.remove(deletionCandidate.id) }
            do {
                try await Task.detached {
                    try DnsmasqConfigurationManager().delete(deletionCandidate)
                }.value
                store.delete(deletionCandidate)
                refreshMappings()
            } catch {
                configurationError = error.localizedDescription
            }
        }
    }

    private func requirePrivilegedHelper() -> Bool {
        guard helperController.state.isReady else {
            destination = .environment
            configurationError = "\(helperController.state.title). \(helperController.state.detail)"
            return false
        }
        return true
    }
}

private enum DomainEditorPresentation: Identifiable {
    case add
    case edit(LocalDomain)

    var id: String {
        switch self {
        case .add:
            return "add"
        case let .edit(domain):
            return domain.id.uuidString
        }
    }

    var domain: LocalDomain? {
        if case let .edit(domain) = self {
            return domain
        }
        return nil
    }
}

private struct BackupImportPresentation: Identifiable {
    let id = UUID()
    let backup: PawxyConfigurationBackup
    let filename: String
}

#Preview {
    ContentView(
        environmentStatus: DevelopmentEnvironmentStatus(
            homebrew: .available(at: "/opt/homebrew/bin/brew"),
            dnsmasq: .available(at: "/opt/homebrew/sbin/dnsmasq")
        )
    )
    .environmentObject(DomainStore(domains: LocalDomain.mockDomains, persistsChanges: false))
}
