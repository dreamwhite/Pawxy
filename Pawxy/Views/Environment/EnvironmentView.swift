//
//  EnvironmentView.swift
//  Pawxy
//

import SwiftUI

struct EnvironmentView: View {
    let status: DevelopmentEnvironmentStatus
    let discoveredDomainCount: Int
    let showsLegacyConfiguration: Bool
    let onCheckAgain: () async -> Void
    let onRefresh: () -> Void
    let onRestart: () -> Void
    let onMigrateLegacy: () -> Void
    let onShowConfiguration: () -> Void
    let onRepairConfiguration: () -> Void
    let latestSnapshotDate: Date?
    let onRestoreSnapshot: () -> Void
    let onCopyDiagnostics: () -> Void

    @State private var isChecking = false
    @State private var showsRestoreConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                toolsPanel
                operationalPanel
                authorizationPanel
                configurationPanel
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Restore the latest configuration snapshot?",
            isPresented: $showsRestoreConfirmation
        ) {
            Button("Restore Snapshot", role: .destructive, action: onRestoreSnapshot)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pawxy will restore every file changed by that transaction and restart dnsmasq.")
        }
    }

    private var authorizationPanel: some View {
        GroupBox("Administrative access") {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text("macOS authorization")
                        .font(.headline)
                    Text("Pawxy asks for administrator authorization only when it applies DNS changes or restarts dnsmasq.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("On demand")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Environment")
                    .font(.largeTitle.bold())
                Text("Tools and configuration detected on this Mac.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCopyDiagnostics) {
                Label("Copy Diagnostics", systemImage: "doc.on.doc")
            }

            Button(action: checkAgain) {
                HStack(spacing: 7) {
                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isChecking
                         ? String(localized: "Checking…")
                         : String(localized: "Check again"))
                }
            }
            .disabled(isChecking)

            Button(action: onRestart) {
                Label("Restart dnsmasq", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!status.isReady)
        }
    }

    private var toolsPanel: some View {
        VStack(spacing: 0) {
            EnvironmentToolRow(name: "Homebrew", availability: status.homebrew)
            Divider().padding(.leading, 58)
            EnvironmentToolRow(name: "dnsmasq", availability: status.dnsmasq)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private var operationalPanel: some View {
        GroupBox("Runtime health") {
            VStack(spacing: 0) {
                EnvironmentComponentRow(
                    name: "DNS service",
                    status: status.service
                )
                Divider().padding(.leading, 46)
                EnvironmentComponentRow(
                    name: "Configuration",
                    status: status.configuration
                )
                Divider().padding(.leading, 46)
                EnvironmentComponentRow(
                    name: "Managed directory",
                    status: status.managedDirectory
                )
            }
            .padding(.horizontal, 8)
        }
    }

    private var configurationPanel: some View {
        GroupBox("Existing configuration") {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(discoveredDomainCount == 1
                         ? String(localized: "1 supported mapping found")
                         : String(localized: "\(discoveredDomainCount) supported mappings found"))
                        .font(.headline)
                    Text("Pawxy reads mappings from dnsmasq and manages a macOS resolver for each enabled Pawxy domain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsLegacyConfiguration {
                        Label("Legacy pawxy.conf detected", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    if showsLegacyConfiguration {
                        Button("Split Pawxy file", action: onMigrateLegacy)
                    }
                    if !status.managedDirectory.isReady {
                        Button("Repair dnsmasq.d Include", action: onRepairConfiguration)
                            .buttonStyle(.borderedProminent)
                            .disabled(!status.homebrew.isAvailable || !status.dnsmasq.isAvailable)
                    }
                    if latestSnapshotDate != nil {
                        Button("Restore Last Snapshot…") {
                            showsRestoreConfirmation = true
                        }
                    }
                    Button(action: onShowConfiguration) {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button("Refresh mappings", action: onRefresh)
                }
            }
            .padding(8)
        }
    }

    private func checkAgain() {
        guard !isChecking else { return }
        isChecking = true

        Task {
            await onCheckAgain()
            isChecking = false
        }
    }
}

private struct EnvironmentComponentRow: View {
    let name: LocalizedStringResource
    let status: EnvironmentComponentStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.systemImage)
                .foregroundStyle(tint)
                .frame(width: 26)
            Text(name)
                .font(.headline)
            Spacer()
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 11)
    }

    private var tint: Color {
        switch status {
        case .ready: .green
        case .warning: .orange
        case .failed: .red
        case .unknown: .secondary
        }
    }
}

private struct EnvironmentToolRow: View {
    let name: LocalizedStringResource
    let availability: DependencyAvailability

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: availability.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(availability.isAvailable ? .green : .red)
                .frame(width: 30)

            Text(name)
                .font(.headline)

            Spacer()

            if let path = availability.path {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Not found")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
    }
}
