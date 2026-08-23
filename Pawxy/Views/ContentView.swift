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
    @EnvironmentObject private var activityLog: ActivityLogStore
    @StateObject private var pendingChanges = PendingDomainChanges()
    @StateObject private var configurationWatcher = DnsmasqConfigurationWatcher()

    @State private var environmentStatus: DevelopmentEnvironmentStatus
    private let dnsmasqManager = DnsmasqConfigurationManager()

    @AppStorage("defaultIPv4Address") private var defaultIPv4Address = "127.0.0.1"

    @State private var destination: SidebarDestination? = .domains
    @State private var searchText = ""
    @State private var discoveredDomains: [DiscoveredDomain] = []
    @State private var hasLegacyConfiguration = false
    @State private var editorPresentation: DomainEditorPresentation?
    @State private var backupImportPresentation: BackupImportPresentation?
    @State private var conflictResolutionCandidate: LocalDomain?
    @State private var showsPendingChanges = false
    @State private var deletionCandidate: LocalDomain?
    @State private var serviceMessage: String?
    @State private var configurationError: String?
    @State private var updatingDomainIDs = Set<UUID>()
    @State private var healthCheckRevision = 0
    @State private var isPerformingServiceOperation = false
    @State private var isRefreshingMappings = false
    @State private var refreshTask: Task<Void, Never>?

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
        .sheet(item: $conflictResolutionCandidate) { domain in
            ConflictResolutionView(domain: domain) { source in
                pendingChanges.stageConflictResolution(for: domain, keeping: source)
            }
        }
        .sheet(isPresented: $showsPendingChanges) {
            PendingChangesView(
                changes: pendingChanges.changes,
                isApplying: isPerformingServiceOperation,
                onApply: applyPendingChanges,
                onDiscard: discardPendingChanges
            )
        }
        .safeAreaInset(edge: .bottom) {
            if !pendingChanges.isEmpty {
                pendingChangesBar
            }
        }
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
                Text("This removes the directive from its dnsmasq configuration file, asks for administrator authorization and restarts the service.")
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
            configurationWatcher.start(
                paths: [
                    dnsmasqManager.rootConfigurationPath,
                    dnsmasqManager.configurationDirectoryPath
                ],
                onChange: refreshMappings
            )
        }
        .onDisappear {
            refreshTask?.cancel()
            configurationWatcher.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addPawxyDomain)) { _ in
            showDomainEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPawxyOverview)) { _ in
            destination = .overview
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

    private var effectiveDomains: [LocalDomain] {
        pendingChanges.domains(applyingTo: store.domains)
    }

    private var pendingChangesBar: some View {
        HStack(spacing: 12) {
            Label(
                pendingChanges.count == 1
                    ? String(localized: "1 pending DNS change")
                    : String(localized: "\(pendingChanges.count) pending DNS changes"),
                systemImage: "tray.full.fill"
            )
            .font(.callout.weight(.semibold))

            Spacer()

            Button("Review") {
                showsPendingChanges = true
            }
            Button("Discard", role: .destructive, action: discardPendingChanges)
            Button("Apply Changes", action: applyPendingChanges)
                .buttonStyle(.borderedProminent)
                .disabled(isPerformingServiceOperation)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
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
                onShowEnvironment: { destination = .environment },
                onCheckEnvironment: checkEnvironment
            )

        case .domains:
            DomainsView(
                domains: effectiveDomains,
                storeError: store.lastError,
                searchText: $searchText,
                isRefreshing: isRefreshingMappings,
                updatingDomainIDs: updatingDomainIDs,
                pendingDomainIDs: Set(pendingChanges.changes.map(\.id)),
                healthCheckRevision: healthCheckRevision,
                onAdd: showDomainEditor,
                onRefresh: refreshMappings,
                onImportBackup: chooseBackupToImport,
                onExportBackup: exportBackup,
                onShowInFinder: revealSourceFile,
                onRepairResolver: repairSystemResolver,
                onResolveConflict: { conflictResolutionCandidate = $0 },
                onEdit: editDomain,
                onDelete: requestDeletion,
                onSetEnabled: setDomainEnabled,
                onSetEnabledMany: setDomainsEnabled,
                onDeleteMany: stageDomainDeletions
            )

        case .environment:
            EnvironmentView(
                status: environmentStatus,
                discoveredDomainCount: discoveredDomains.count,
                showsLegacyConfiguration: hasLegacyConfiguration,
                onCheckAgain: {
                    await refreshEnvironmentStatus()
                },
                onRefresh: refreshMappings,
                onRestart: restartDnsmasq,
                onMigrateLegacy: migrateLegacyConfiguration,
                onShowConfiguration: {
                    revealFile(dnsmasqManager.rootConfigurationPath)
                },
                onRepairConfiguration: repairManagedConfigurationInclude,
                latestSnapshotDate: dnsmasqManager.latestSnapshotDate,
                onRestoreSnapshot: restoreLatestConfigurationSnapshot,
                onCopyDiagnostics: copyDiagnostics
            )

        case .activity:
            ActivityLogView(
                environmentStatus: environmentStatus,
                domains: store.domains
            )
        }
    }

    private func domainEditor(_ presentation: DomainEditorPresentation) -> some View {
        DomainEditorView(
            domain: presentation.domain,
            existingDomains: effectiveDomains,
            defaultAddress: defaultIPv4Address
        ) { domain in
            if let existingDomain = presentation.domain {
                pendingChanges.stageUpdate(original: existingDomain, updated: domain)
            } else {
                pendingChanges.stageAdd(domain)
            }
        }
    }

    private func backupImportSheet(_ presentation: BackupImportPresentation) -> some View {
        BackupImportView(
            backup: presentation.backup,
            filename: presentation.filename,
            existingDomainNames: Set(effectiveDomains.map { $0.domain.lowercased() })
        ) { domains in
            let currentNames = Set(
                DnsmasqConfigScanner().scan().map { $0.domain.lowercased() }
            )
            if let conflict = domains.first(where: {
                currentNames.contains($0.domain.lowercased())
            }) {
                throw DnsmasqConfigurationManager.ManagerError.duplicateDomain(conflict.domain)
            }

            for domain in domains {
                pendingChanges.stageAdd(domain)
            }
            serviceMessage = domains.count == 1
                ? String(localized: "Added one imported mapping to pending changes.")
                : String(localized: "Added \(domains.count) imported mappings to pending changes.")
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
        destination = .domains
        editorPresentation = .add
    }

    private func editDomain(_ domain: LocalDomain) {
        editorPresentation = .edit(domain)
    }

    private func requestDeletion(_ domain: LocalDomain) {
        deletionCandidate = domain
    }

    private func refreshMappings() {
        refreshTask?.cancel()
        isRefreshingMappings = true
        refreshTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                let domains = DnsmasqConfigScanner().scan()
                let hasLegacy = DnsmasqConfigurationManager().hasLegacyManagedConfiguration
                return (domains, hasLegacy)
            }.value
            guard !Task.isCancelled else { return }
            discoveredDomains = snapshot.0
            store.synchronize(with: snapshot.0)
            hasLegacyConfiguration = snapshot.1
            healthCheckRevision &+= 1
            isRefreshingMappings = false
        }
    }

    private func restartDnsmasq() {
        guard !isPerformingServiceOperation else { return }
        isPerformingServiceOperation = true
        Task {
            defer { isPerformingServiceOperation = false }
            do {
                try await Task.detached {
                    try DnsmasqConfigurationManager().restart()
                }.value
                refreshMappings()
                activityLog.record(
                    .service,
                    title: String(localized: "dnsmasq restarted")
                )
                serviceMessage = String(localized: "The configuration is valid and dnsmasq was restarted successfully.")
            } catch {
                recordFailure(.service, title: String(localized: "dnsmasq restart failed"), error: error)
                configurationError = error.localizedDescription
            }
        }
    }

    private func checkEnvironment() {
        Task { await refreshEnvironmentStatus() }
    }

    private func refreshEnvironmentStatus() async {
        let status = await Task.detached(priority: .userInitiated) {
            DependencyChecker().check()
        }.value
        guard !Task.isCancelled else { return }
        environmentStatus = status
    }

    private func repairManagedConfigurationInclude() {
        guard !isPerformingServiceOperation else { return }
        isPerformingServiceOperation = true
        Task {
            defer { isPerformingServiceOperation = false }
            do {
                let changed = try await Task.detached(priority: .userInitiated) {
                    try DnsmasqConfigurationManager().repairManagedConfigurationInclude()
                }.value
                await refreshEnvironmentStatus()
                refreshMappings()
                serviceMessage = changed
                    ? String(localized: "dnsmasq.d was added to dnsmasq.conf and dnsmasq was restarted.")
                    : String(localized: "dnsmasq.d is already included by dnsmasq.conf.")
                activityLog.record(
                    .configuration,
                    title: changed
                        ? String(localized: "Repaired dnsmasq.d include")
                        : String(localized: "Checked dnsmasq.d include")
                )
            } catch {
                recordFailure(.configuration, title: String(localized: "dnsmasq.d repair failed"), error: error)
                configurationError = error.localizedDescription
            }
        }
    }

    private func restoreLatestConfigurationSnapshot() {
        guard !isPerformingServiceOperation else { return }
        isPerformingServiceOperation = true
        Task {
            defer { isPerformingServiceOperation = false }
            do {
                let restoredDate = try await Task.detached(priority: .userInitiated) {
                    try DnsmasqConfigurationManager().restoreLatestSnapshot()
                }.value
                refreshMappings()
                await refreshEnvironmentStatus()
                if let restoredDate {
                    activityLog.record(
                        .configuration,
                        title: String(localized: "Configuration snapshot restored")
                    )
                    serviceMessage = String(localized: "Restored the configuration snapshot from \(restoredDate.formatted(date: .abbreviated, time: .shortened)).")
                } else {
                    serviceMessage = String(localized: "No configuration snapshot is available.")
                }
            } catch {
                recordFailure(.configuration, title: String(localized: "Configuration restore failed"), error: error)
                configurationError = error.localizedDescription
            }
        }
    }

    private func copyDiagnostics() {
        let report = PawxyDiagnosticsService().report(
            status: environmentStatus,
            domains: store.domains,
            recentActivity: activityLog.entries
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        activityLog.record(.diagnostics, title: String(localized: "Diagnostics copied"))
        serviceMessage = String(localized: "Diagnostics copied to the clipboard.")
    }

    private func migrateLegacyConfiguration() {
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
                activityLog.record(
                    .configuration,
                    title: String(localized: "Migrated legacy configuration"),
                    detail: String(localized: "\(count) mappings processed")
                )
            } catch {
                recordFailure(.configuration, title: String(localized: "Legacy migration failed"), error: error)
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
            activityLog.record(
                .backup,
                title: String(localized: "Backup opened for review")
            )
        } catch {
            recordFailure(.backup, title: String(localized: "Backup import failed"), error: error)
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
            activityLog.record(
                .backup,
                title: String(localized: "Backup exported"),
                detail: String(localized: "\(store.domains.count) mappings exported")
            )
        } catch {
            recordFailure(.backup, title: String(localized: "Backup export failed"), error: error)
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
        guard !updatingDomainIDs.contains(domain.id), domain.enabled != enabled
        else {
            return
        }
        var updated = domain
        updated.enabled = enabled
        let original = pendingChanges.change(for: domain.id)?.originalDomain
            ?? store.domains.first(where: { $0.id == domain.id })
            ?? domain
        pendingChanges.stageUpdate(original: original, updated: updated)
    }

    private func setDomainsEnabled(_ enabled: Bool, domains: [LocalDomain]) {
        for domain in domains where domain.enabled != enabled {
            setDomainEnabled(enabled, domain: domain)
        }
    }

    private func stageDomainDeletions(_ domains: [LocalDomain]) {
        for domain in domains {
            pendingChanges.stageDelete(domain)
        }
    }

    private func repairSystemResolver(for domain: LocalDomain) {
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
                activityLog.record(
                    .resolver,
                    title: installed
                        ? String(localized: "System resolver installed")
                        : String(localized: "System resolver checked")
                )
                healthCheckRevision &+= 1
            } catch {
                recordFailure(.resolver, title: String(localized: "System resolver repair failed"), error: error)
                configurationError = error.localizedDescription
            }
        }
    }

    private func deleteSelectedDomain() {
        guard let deletionCandidate else { return }
        self.deletionCandidate = nil
        guard !updatingDomainIDs.contains(deletionCandidate.id) else { return }
        pendingChanges.stageDelete(deletionCandidate)
    }

    private func applyPendingChanges() {
        guard !pendingChanges.isEmpty, !isPerformingServiceOperation else { return }
        let changes = pendingChanges.changes
        isPerformingServiceOperation = true
        Task {
            defer { isPerformingServiceOperation = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DnsmasqConfigurationManager().applyPendingChanges(changes)
                }.value
                pendingChanges.discardAll()
                showsPendingChanges = false
                refreshMappings()
                serviceMessage = changes.count == 1
                    ? String(localized: "Applied one DNS change and restarted dnsmasq.")
                    : String(localized: "Applied \(changes.count) DNS changes and restarted dnsmasq.")
                activityLog.record(
                    .configuration,
                    title: String(localized: "Applied DNS changes"),
                    detail: changes.count == 1
                        ? String(localized: "1 change applied")
                        : String(localized: "\(changes.count) changes applied")
                )
            } catch {
                recordFailure(.configuration, title: String(localized: "DNS changes failed"), error: error)
                configurationError = error.localizedDescription
            }
        }
    }

    private func discardPendingChanges() {
        pendingChanges.discardAll()
        showsPendingChanges = false
    }

    private func recordFailure(
        _ kind: ActivityLogEntry.Kind,
        title: String,
        error: Error
    ) {
        activityLog.record(
            kind,
            title: title,
            detail: error.localizedDescription,
            succeeded: false
        )
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
