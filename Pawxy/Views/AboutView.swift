//
//  AboutView.swift
//  Pawxy
//

import SwiftUI

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var softwareUpdates: SoftwareUpdateController

    private let repositoryURL = URL(string: "https://github.com/dreamwhite/Pawxy")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 18) {
            AboutAppIcon()

            VStack(spacing: 4) {
                Text("Pawxy")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text("Local DNS management for macOS developers")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(String(localized: "Version \(version) (\(build))"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text("A native macOS utility for managing dnsmasq mappings, system resolvers, and local domain health from one focused workspace.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 450)

            HStack(spacing: 10) {
                AboutFeature(
                    title: "Discover mappings",
                    detail: "Read existing dnsmasq configuration automatically.",
                    systemImage: "doc.text.magnifyingglass"
                )
                AboutFeature(
                    title: "Manage resolvers",
                    detail: "Keep macOS routing in sync with local domains.",
                    systemImage: "network.badge.shield.half.filled"
                )
                AboutFeature(
                    title: "Verify DNS",
                    detail: "Test every mapping against dnsmasq and macOS.",
                    systemImage: "checkmark.circle"
                )
            }

            Divider()

            HStack(spacing: 10) {
                Button("Check for Updates…") {
                    softwareUpdates.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!softwareUpdates.canCheckForUpdates)

                Button("Open Help") {
                    openWindow(id: "pawxy-help")
                }
                .buttonStyle(.bordered)

                Link(destination: repositoryURL) {
                    Label("GitHub", systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: 3) {
                Text("Built for local development with dnsmasq.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("© 2026 Dreamcorp. All rights reserved.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 540, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AboutAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.76), .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: 58, height: 58)
                .offset(x: -16, y: -17)

            Image(systemName: "pawprint.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
        .frame(width: 82, height: 82)
        .shadow(color: .blue.opacity(0.22), radius: 14, y: 7)
        .accessibilityHidden(true)
    }
}

private struct AboutFeature: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(width: 30, height: 30)
                .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.48), lineWidth: 1)
        }
    }
}

#Preview {
    AboutView()
        .environmentObject(SoftwareUpdateController())
}
