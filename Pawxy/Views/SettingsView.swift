//
//  SettingsView.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultIPv4Address") private var defaultIPv4Address = "127.0.0.1"
    @AppStorage("alwaysShowEnvironmentSetup") private var alwaysShowEnvironmentSetup = false
    @AppStorage("didCompleteEnvironmentSetup") private var didCompleteEnvironmentSetup = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some View {
        TabView {
            Form {
                Section("New domains") {
                    TextField("Default IP address", text: $defaultIPv4Address)
                    Text("Pawxy domains cover the domain and its subdomains using a dnsmasq address directive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Startup") {
                    Toggle("Show environment summary at launch", isOn: $alwaysShowEnvironmentSetup)

                    Button("Show setup on next launch") {
                        didCompleteEnvironmentSetup = false
                    }
                }

                Section("Menu Bar") {
                    Toggle("Show Pawxy in the menu bar", isOn: $showMenuBarExtra)

                    Text("Use the menu bar to check local DNS, restart dnsmasq, repair missing resolvers, and open Pawxy without keeping its window visible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            EnvironmentSettingsView()
                .tabItem {
                    Label("Environment", systemImage: "wrench.and.screwdriver")
                }

            UpdateSettingsView()
                .tabItem {
                    Label("Updates", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
        }
        .frame(width: 540, height: 390)
    }
}

private struct UpdateSettingsView: View {
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController

    var body: some View {
        Form {
            Section("Software updates") {
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { softwareUpdates.automaticallyChecksForUpdates },
                        set: softwareUpdates.setAutomaticallyChecksForUpdates
                    )
                )

                Toggle(
                    "Automatically download updates",
                    isOn: Binding(
                        get: { softwareUpdates.automaticallyDownloadsUpdates },
                        set: softwareUpdates.setAutomaticallyDownloadsUpdates
                    )
                )
                .disabled(!softwareUpdates.automaticallyChecksForUpdates)
            }

            Section {
                Button("Check for Updates Now…") {
                    softwareUpdates.checkForUpdates()
                }
                .disabled(!softwareUpdates.canCheckForUpdates)
            }

            Section {
                Text("Updates are downloaded from GitHub Releases and cryptographically verified by Sparkle before installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EnvironmentSettingsView: View {
    @State private var status = DependencyChecker().check()
    @State private var isChecking = false

    var body: some View {
        Form {
            Section("Local tools") {
                SettingsRequirementRow(name: "Homebrew", availability: status.homebrew)
                SettingsRequirementRow(name: "dnsmasq", availability: status.dnsmasq)
            }


            Section("Runtime health") {
                LabeledContent("DNS service") {
                    SettingsComponentStatus(status: status.service)
                }
                LabeledContent("Configuration") {
                    SettingsComponentStatus(status: status.configuration)
                }
                LabeledContent("Managed directory") {
                    SettingsComponentStatus(status: status.managedDirectory)
                }
            }

            Section("Administrative access") {
                LabeledContent("Authorization") {
                    Label("On demand", systemImage: "lock.shield.fill")
                        .foregroundStyle(.blue)
                }

                Text("Pawxy uses the standard macOS administrator prompt when it modifies dnsmasq, manages system resolvers or restarts the service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    guard !isChecking else { return }
                    isChecking = true
                    Task {
                        status = await Task.detached {
                            DependencyChecker().check()
                        }.value
                        isChecking = false
                    }
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isChecking)
            }

            Section {
                Text("Pawxy synchronizes mappings directly from dnsmasq, validates paths, creates recoverable backups, tests the complete configuration and requests administrator authorization only when required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsComponentStatus: View {
    let status: EnvironmentComponentStatus

    var body: some View {
        Label(status.detail, systemImage: status.systemImage)
            .foregroundStyle(tint)
            .font(.caption)
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

private struct SettingsRequirementRow: View {
    let name: String
    let availability: DependencyAvailability

    var body: some View {
        LabeledContent(name) {
            VStack(alignment: .trailing, spacing: 2) {
                Label(
                    availability.isAvailable
                        ? String(localized: "Ready")
                        : String(localized: "Not found"),
                    systemImage: availability.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(availability.isAvailable ? .green : .red)

                if let path = availability.path {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(SoftwareUpdateController())
}
