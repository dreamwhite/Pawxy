//
//  PawxyMenuBarView.swift
//  Pawxy
//

import AppKit
import SwiftUI

struct PawxyMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: DomainStore

    @State private var environmentStatus = DependencyChecker().check()
    @State private var healthResults: [UUID: DomainResolutionTestResult] = [:]
    @State private var isChecking = false
    @State private var isRestarting = false
    @State private var isRepairingResolvers = false
    @State private var activityMessage: String?

    private let configurationManager = DnsmasqConfigurationManager()

    var body: some View {
        Group {
            Label(statusTitle, systemImage: statusSystemImage)
                .disabled(true)

            Text(statusDetail)
                .disabled(true)

            if let activityMessage {
                Text(activityMessage)
                    .disabled(true)
            }

            Divider()

            Button {
                openMainWindow(notification: .showPawxyOverview)
            } label: {
                Label("Open Pawxy", systemImage: "macwindow")
            }

            Button {
                openMainWindow(notification: .addPawxyDomain)
            } label: {
                Label("Add Domain…", systemImage: "plus")
            }

            Button {
                Task { await refreshAndCheck() }
            } label: {
                Label(
                    isChecking ? "Checking Domains…" : "Refresh & Check Domains",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(isBusy)

            Button {
                restartDnsmasq()
            } label: {
                Label(
                    isRestarting ? "Restarting dnsmasq…" : "Restart dnsmasq",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                )
            }
            .disabled(isBusy || !environmentStatus.isReady)

            if attentionCount > 0 || !resolverRepairCandidates.isEmpty {
                Divider()

                Button {
                    openMainWindow(notification: .showPawxyOverview)
                } label: {
                    Label("View Issues", systemImage: "exclamationmark.triangle")
                }

                if !resolverRepairCandidates.isEmpty {
                    Button {
                        repairMissingResolvers()
                    } label: {
                        Label(
                            isRepairingResolvers
                                ? "Repairing Resolvers…"
                                : "Repair Missing Resolvers…",
                            systemImage: "wrench.and.screwdriver"
                        )
                    }
                    .disabled(isBusy)
                }
            }

            Divider()

            Button(action: openConfigurationFolder) {
                Label("Open Configuration Folder", systemImage: "folder")
            }
            .disabled(!configurationDirectoryExists)

            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }

            Button {
                openAuxiliaryWindow(id: "pawxy-about")
            } label: {
                Label("About Pawxy", systemImage: "info.circle")
            }

            Divider()

            Button("Quit Pawxy") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            await refreshAndCheck()
        }
        .onChange(of: store.domains) {
            Task { await refreshAndCheck() }
        }
    }

    private var isBusy: Bool {
        isChecking || isRestarting || isRepairingResolvers
    }

    private var enabledDomains: [LocalDomain] {
        store.domains.filter(\.enabled)
    }

    private var activeCount: Int {
        guard !healthResults.isEmpty else {
            return enabledDomains.filter {
                if case .conflict = $0.origin { return false }
                return true
            }.count
        }
        return healthResults.values.reduce(into: 0) { count, result in
            if case .active = result {
                count += 1
            }
        }
    }

    private var attentionCount: Int {
        let conflicts = enabledDomains.filter {
            if case .conflict = $0.origin { return true }
            return false
        }.count
        return conflicts + healthResults.values.filter(\.needsAttention).count
    }

    private var resolverRepairCandidates: [LocalDomain] {
        enabledDomains.filter { domain in
            healthResults[domain.id]?.requiresResolverRepair == true
        }
    }

    private var statusTitle: String {
        if !environmentStatus.isReady {
            return String(localized: "Environment needs attention")
        }
        if attentionCount > 0 {
            return attentionCount == 1
                ? String(localized: "1 DNS issue found")
                : String(localized: "\(attentionCount) DNS issues found")
        }
        return String(localized: "Local DNS is healthy")
    }

    private var statusDetail: String {
        if isChecking {
            return String(localized: "Checking environment and domain resolution…")
        }
        return String(localized: "\(activeCount) active · \(store.domains.count) configured")
    }

    private var statusSystemImage: String {
        if isChecking {
            return "arrow.clockwise"
        }
        if !environmentStatus.isReady || attentionCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var configurationDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: configurationManager.configurationDirectoryPath)
    }

    private func openMainWindow(notification: Notification.Name? = nil) {
        openWindow(id: "pawxy-main")
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard let notification else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    private func openAuxiliaryWindow(id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func openConfigurationFolder() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: configurationManager.configurationDirectoryPath, isDirectory: true)
        )
    }

    private func refreshAndCheck(clearActivityMessage: Bool = true) async {
        guard !isBusy else { return }
        isChecking = true
        defer { isChecking = false }
        if clearActivityMessage {
            activityMessage = nil
        }
        environmentStatus = DependencyChecker().check()

        let discovered = await Task.detached {
            DnsmasqConfigScanner().scan()
        }.value
        store.synchronize(with: discovered)

        let collected = await DomainHealthCheckService().check(store.domains)

        guard !Task.isCancelled else { return }
        healthResults = collected
    }

    private func restartDnsmasq() {
        guard !isBusy else { return }
        isRestarting = true
        activityMessage = nil

        Task {
            do {
                try await Task.detached {
                    try DnsmasqConfigurationManager().restart()
                }.value
                isRestarting = false
                activityMessage = String(localized: "dnsmasq restarted successfully")
                await refreshAndCheck(clearActivityMessage: false)
            } catch {
                isRestarting = false
                presentOperationError(error)
            }
        }
    }

    private func repairMissingResolvers() {
        let candidates = resolverRepairCandidates
        guard !candidates.isEmpty, !isBusy else { return }
        isRepairingResolvers = true
        activityMessage = nil

        Task {
            do {
                let installedCount = try await Task.detached {
                    try DnsmasqConfigurationManager().ensureSystemResolvers(for: candidates)
                }.value
                isRepairingResolvers = false
                activityMessage = installedCount == 1
                    ? String(localized: "Installed one missing resolver")
                    : String(localized: "Installed \(installedCount) missing resolvers")
                await refreshAndCheck(clearActivityMessage: false)
            } catch {
                isRepairingResolvers = false
                presentOperationError(error)
            }
        }
    }

    private func presentOperationError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Pawxy operation failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
