//
//  HelpView.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import SwiftUI

struct HelpView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 68, height: 68)
                        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pawxy")
                            .font(.largeTitle.bold())
                        Text("Local DNS management for macOS developers")
                            .foregroundStyle(.secondary)
                        Text("Version \(version) (\(build))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                helpSection(
                    title: "Getting started",
                    systemImage: "play.circle",
                    text: "Open Local Domains to see mappings detected from dnsmasq automatically, or create a new domain with ⌘N. Use ⌘R after changing configuration files outside Pawxy."
                )

                helpSection(
                    title: "Existing dnsmasq files",
                    systemImage: "doc.text.magnifyingglass",
                    text: "dnsmasq is the source of truth. Pawxy records each mapping’s source file and line; new Pawxy domains use one descriptive .conf file per mapping. Existing external files retain their original layout."
                )

                helpSection(
                    title: "macOS resolvers",
                    systemImage: "network.badge.shield.half.filled",
                    text: "Each enabled Pawxy domain also gets a managed file in /etc/resolver so macOS sends that domain to dnsmasq. For pre-existing mappings, use Repair system resolver from the domain menu. Avoid .local for new domains because macOS reserves it for Bonjour."
                )

                helpSection(
                    title: "Privileged helper",
                    systemImage: "checkmark.shield",
                    text: "Pawxy uses a signed, app-bundled XPC service for protected dnsmasq and resolver changes. macOS asks you to approve it once in Login Items & Extensions; Pawxy never sends arbitrary shell commands to the service."
                )

                helpSection(
                    title: "Restarting dnsmasq",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                    text: "Restart dnsmasq first validates the complete configuration, then restarts the system service. It does not rewrite configuration files."
                )

                helpSection(
                    title: "Portable backups",
                    systemImage: "archivebox",
                    text: "Export Backup saves domains, addresses, wildcard options and enabled states in a versioned JSON file. Import Backup previews its contents, skips domains already present and creates one dnsmasq .conf file for each new mapping."
                )

                helpSection(
                    title: "Environment",
                    systemImage: "wrench.and.screwdriver",
                    text: "The Environment screen shows where Homebrew and dnsmasq were found. Use Check again after installing or updating either tool."
                )

                Divider()

                HStack {
                    Text("Bundle identifier")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Bundle.main.bundleIdentifier ?? "com.dreamcorp.Pawxy")
                        .font(.callout.monospaced())
                }

                Text("© 2026 Dreamcorp. All rights reserved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(30)
        }
        .frame(width: 600, height: 520)
    }

    private func helpSection(
        title: LocalizedStringResource,
        systemImage: String,
        text: LocalizedStringResource
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    HelpView()
}
