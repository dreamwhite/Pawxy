//
//  EnvironmentSetupView.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import SwiftUI

struct AppRootView: View {
    @AppStorage("didCompleteEnvironmentSetup") private var didCompleteSetup = false
    @AppStorage("alwaysShowEnvironmentSetup") private var alwaysShowEnvironmentSetup = false
    @State private var status: DevelopmentEnvironmentStatus?
    @State private var isChecking = false
    @State private var didContinueThisSession = false

    var body: some View {
        Group {
            if isChecking || status == nil {
                checkingView
            } else if let status,
                      status.hasRequiredTools,
                      didCompleteSetup,
                      (!alwaysShowEnvironmentSetup || didContinueThisSession) {
                ContentView(environmentStatus: status)
            } else if let status {
                EnvironmentSetupView(
                    status: status,
                    isChecking: isChecking,
                    onCheckAgain: checkEnvironment,
                    onContinue: {
                        didCompleteSetup = true
                        didContinueThisSession = true
                    }
                )
            }
        }
        .task {
            checkEnvironment()
        }
    }

    private var checkingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text("Checking your development environment…")
                .font(.headline)

            Text("Looking for Homebrew and dnsmasq")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 680, minHeight: 500)
    }

    private func checkEnvironment() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            status = await Task.detached(priority: .userInitiated) {
                DependencyChecker().check()
            }.value
            isChecking = false
        }
    }
}

private struct EnvironmentSetupView: View {
    let status: DevelopmentEnvironmentStatus
    let isChecking: Bool
    let onCheckAgain: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 70, height: 70)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                Text("Let’s get Pawxy ready")
                    .font(.largeTitle.bold())

                Text("Pawxy needs these local development tools before it can manage DNS.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 0) {
                RequirementRow(
                    name: "Homebrew",
                    description: "Package manager used to locate dnsmasq",
                    availability: status.homebrew
                )

                Divider()
                    .padding(.leading, 58)

                RequirementRow(
                    name: "dnsmasq",
                    description: "Local DNS resolver used by Pawxy",
                    availability: status.dnsmasq
                )
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.6), lineWidth: 1)
            }

            if !status.isReady {
                missingDependencyHelp
            }

            HStack(spacing: 10) {
                Button {
                    onCheckAgain()
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .disabled(isChecking)

                Button("Continue") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!status.hasRequiredTools)
            }

            Text("This setup check is read-only. macOS asks for administrator authorization only when Pawxy applies DNS changes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(38)
        .frame(minWidth: 680, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var missingDependencyHelp: some View {
        if !status.homebrew.isAvailable {
            VStack(spacing: 5) {
                Text("Homebrew was not found in the standard installation paths.")
                    .font(.callout.weight(.medium))

                Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
                    .font(.callout)
            }
        } else if !status.dnsmasq.isAvailable {
            VStack(spacing: 7) {
                Text("Install dnsmasq, then check again:")
                    .font(.callout.weight(.medium))

                Text("brew install dnsmasq")
                    .font(.callout.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(status.service.detail, systemImage: status.service.systemImage)
                Label(status.configuration.detail, systemImage: status.configuration.systemImage)
                Label(status.managedDirectory.detail, systemImage: status.managedDirectory.systemImage)
                Text("Continue to open Environment, where Pawxy can repair the managed include or restart dnsmasq.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

private struct RequirementRow: View {
    let name: LocalizedStringResource
    let description: LocalizedStringResource
    let availability: DependencyAvailability

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: availability.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(availability.isAvailable ? .green : .red)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(availability.isAvailable
                     ? String(localized: "Ready")
                     : String(localized: "Not found"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(availability.isAvailable ? .green : .red)

                if let path = availability.path {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
    }
}

#Preview("Ready") {
    EnvironmentSetupView(
        status: DevelopmentEnvironmentStatus(
            homebrew: .available(at: "/opt/homebrew/bin/brew"),
            dnsmasq: .available(at: "/opt/homebrew/sbin/dnsmasq")
        ),
        isChecking: false,
        onCheckAgain: {},
        onContinue: {}
    )
}

#Preview("Missing dnsmasq") {
    EnvironmentSetupView(
        status: DevelopmentEnvironmentStatus(
            homebrew: .available(at: "/opt/homebrew/bin/brew"),
            dnsmasq: .missing
        ),
        isChecking: false,
        onCheckAgain: {},
        onContinue: {}
    )
}
