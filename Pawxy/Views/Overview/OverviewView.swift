//
//  OverviewView.swift
//  Pawxy
//

import SwiftUI

struct OverviewView: View {
    let domains: [LocalDomain]
    let environmentStatus: DevelopmentEnvironmentStatus
    let onShowDomains: () -> Void
    let onAddDomain: () -> Void
    let onRefresh: () -> Void
    let onRestart: () -> Void
    let onRevealFile: (String) -> Void
    let onShowEnvironment: () -> Void

    private var enabledDomains: [LocalDomain] { domains.filter(\.enabled) }
    private var disabledDomains: [LocalDomain] { domains.filter { !$0.enabled } }

    private var configurationSources: [OverviewConfigurationSource] {
        let grouped = Dictionary(grouping: domains) { domain in
            switch domain.origin {
            case .manual:
                return ""
            case let .imported(file, _):
                return file
            }
        }

        return grouped
            .map { path, domains in
                OverviewConfigurationSource(
                    path: path.isEmpty ? nil : path,
                    name: path.isEmpty
                        ? String(localized: "Pawxy store")
                        : URL(fileURLWithPath: path).lastPathComponent,
                    count: domains.count
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusSection
                domainsSection
                configurationSection
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Overview")
                    .font(.largeTitle.bold())
                Text("Monitor and manage your local DNS workspace.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button(action: onAddDomain) {
                Label("Add domain", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var statusSection: some View {
        OverviewSection(title: "Local DNS", systemImage: "checkmark.shield") {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: environmentStatus.isReady
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(environmentStatus.isReady ? .green : .orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(environmentStatus.isReady
                             ? String(localized: "Environment ready")
                             : String(localized: "Environment needs attention"))
                            .font(.headline)
                        Text(environmentStatus.isReady
                             ? String(localized: "Homebrew and dnsmasq are available on this Mac.")
                             : String(localized: "One or more required tools could not be found."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    HStack(spacing: 8) {
                        Button("View environment", action: onShowEnvironment)
                        Button(action: onRestart) {
                            Label("Restart dnsmasq", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!environmentStatus.isReady)
                    }
                }

                Divider()

                HStack(spacing: 0) {
                    OverviewMetric(title: "Domains", value: domains.count, tint: .blue)
                    Divider().frame(height: 34)
                    OverviewMetric(title: "Active", value: enabledDomains.count, tint: .green)
                    Divider().frame(height: 34)
                    OverviewMetric(title: "Disabled", value: disabledDomains.count, tint: .secondary)
                    Divider().frame(height: 34)
                    OverviewMetric(
                        title: "DNS zones",
                        value: domains.filter(\.wildcard).count,
                        tint: .orange
                    )
                }
            }
        }
    }

    private var domainsSection: some View {
        OverviewSection(
            title: "Managed domains",
            systemImage: "globe",
            actionTitle: domains.isEmpty ? nil : "View all",
            action: onShowDomains
        ) {
            if domains.isEmpty {
                ContentUnavailableView(
                    "No domains yet",
                    systemImage: "globe.badge.chevron.backward",
                    description: Text("Refresh dnsmasq mappings or create your first domain.")
                )
                .frame(minHeight: 160)
            } else {
                VStack(spacing: 0) {
                    ForEach(domains.prefix(6)) { domain in
                        OverviewDomainRow(domain: domain)

                        if domain.id != domains.prefix(6).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var configurationSection: some View {
        OverviewSection(title: "Configuration sources", systemImage: "doc.text") {
            if configurationSources.isEmpty {
                Text("No configuration files in use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(configurationSources) { source in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .fontWeight(.medium)
                                Text("dnsmasq configuration")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(source.count == 1
                                 ? String(localized: "1 mapping")
                                 : String(localized: "\(source.count) mappings"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if let path = source.path {
                                Button {
                                    onRevealFile(path)
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help(String(localized: "Show \(source.name) in Finder"))
                            }
                        }
                        .padding(.vertical, 10)

                        if source.id != configurationSources.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

private struct OverviewConfigurationSource: Identifiable {
    var id: String { path ?? name }
    let path: String?
    let name: String
    let count: Int
}

private struct OverviewSection<Content: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    let actionTitle: LocalizedStringResource?
    let action: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        title: LocalizedStringResource,
        systemImage: String,
        actionTitle: LocalizedStringResource? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
    }
}

private struct OverviewMetric: View {
    let title: LocalizedStringResource
    let value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title3.bold())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

private struct OverviewDomainRow: View {
    let domain: LocalDomain

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(domain.enabled ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(domain.domain)
                    .fontWeight(.medium)
                Text(domain.origin.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(domain.address)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(domain.enabled
                 ? String(localized: "On")
                 : String(localized: "Off"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(domain.enabled ? .green : .secondary)
                .frame(width: 25, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }
}
