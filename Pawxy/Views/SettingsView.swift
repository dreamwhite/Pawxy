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

    var body: some View {
        TabView {
            Form {
                Section("New domains") {
                    TextField("Default IPv4 address", text: $defaultIPv4Address)
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
    @EnvironmentObject private var helperController: PrivilegedHelperController
    @State private var status = DependencyChecker().check()

    var body: some View {
        Form {
            Section("Local tools") {
                SettingsRequirementRow(name: "Homebrew", availability: status.homebrew)
                SettingsRequirementRow(name: "dnsmasq", availability: status.dnsmasq)
            }

            Section("Privileged helper") {
                LabeledContent("System service") {
                    Label(
                        helperController.state.title,
                        systemImage: helperController.state.systemImage
                    )
                    .foregroundStyle(helperController.state.isReady ? .green : .orange)
                }

                Text(helperController.state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch helperController.state {
                case .requiresApproval:
                    Button("Open Login Items & Extensions") {
                        helperController.openApprovalSettings()
                    }
                case .notInstalled, .missingFromBundle, .failed:
                    Button("Install helper") {
                        helperController.install()
                    }
                case .unreachable:
                    Button("Reinstall helper") {
                        helperController.reinstall()
                    }
                default:
                    EmptyView()
                }
            }

            Section {
                Button {
                    status = DependencyChecker().check()
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
            }

            Section {
                Text("Pawxy synchronizes mappings directly from dnsmasq. Its signed privileged helper validates paths, backs up changes, tests the complete configuration and restarts the service without AppleScript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        .environmentObject(PrivilegedHelperController.shared)
        .environmentObject(SoftwareUpdateController())
}
