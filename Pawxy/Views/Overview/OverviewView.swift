//
//  OverviewView.swift
//  Pawxy
//

import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var helperController: PrivilegedHelperController

    let domains: [LocalDomain]
    let environmentStatus: DevelopmentEnvironmentStatus
    let onShowDomains: () -> Void
    let onAddDomain: () -> Void
    let onRefresh: () -> Void
    let onRestart: () -> Void
    let onRevealFile: (String) -> Void
    let onShowEnvironment: () -> Void
    let onCheckEnvironment: () -> Void

    @State private var healthResults: [UUID: DomainResolutionTestResult] = [:]
    @State private var isCheckingHealth = false
    @State private var refreshRevision = 0

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

    private var configurationDirectory: String {
        if let source = configurationSources.compactMap(\.path).first {
            return URL(fileURLWithPath: source).deletingLastPathComponent().path
        }
        if let brewPath = environmentStatus.homebrew.path {
            return URL(fileURLWithPath: brewPath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("etc/dnsmasq.d", isDirectory: true)
                .path
        }
        return String(localized: "No configuration directory detected")
    }

    private var attentionItems: [OverviewAttentionItem] {
        var items: [OverviewAttentionItem] = []

        if !environmentStatus.homebrew.isAvailable {
            items.append(
                OverviewAttentionItem(
                    id: "homebrew",
                    title: String(localized: "Homebrew not found"),
                    detail: String(localized: "Install Homebrew before managing local DNS."),
                    systemImage: "shippingbox.fill",
                    tint: .red
                )
            )
        }
        if !environmentStatus.dnsmasq.isAvailable {
            items.append(
                OverviewAttentionItem(
                    id: "dnsmasq",
                    title: String(localized: "dnsmasq not found"),
                    detail: String(localized: "Install dnsmasq before managing local domains."),
                    systemImage: "network.slash",
                    tint: .red
                )
            )
        }
        if helperController.state != .checking && !helperController.state.isReady {
            items.append(
                OverviewAttentionItem(
                    id: "helper",
                    title: helperController.state.title,
                    detail: helperController.state.detail,
                    systemImage: helperController.state.systemImage,
                    tint: .orange
                )
            )
        }

        for domain in enabledDomains {
            guard let result = healthResults[domain.id] else { continue }
            switch result {
            case .active, .disabled:
                break
            case .mdnsConflict:
                items.append(
                    OverviewAttentionItem(
                        id: "\(domain.id)-bonjour",
                        title: domain.domain,
                        detail: String(localized: "Bonjour conflict: .local is reserved for mDNS."),
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                )
            case .notRouted:
                items.append(
                    OverviewAttentionItem(
                        id: "\(domain.id)-resolver",
                        title: domain.domain,
                        detail: String(localized: "The macOS system resolver is missing."),
                        systemImage: "network.badge.shield.half.filled",
                        tint: .orange
                    )
                )
            case .noAnswer:
                items.append(
                    OverviewAttentionItem(
                        id: "\(domain.id)-answer",
                        title: domain.domain,
                        detail: String(localized: "dnsmasq returned no address for this domain."),
                        systemImage: "xmark.circle.fill",
                        tint: .red
                    )
                )
            case .mismatch:
                items.append(
                    OverviewAttentionItem(
                        id: "\(domain.id)-mismatch",
                        title: domain.domain,
                        detail: String(localized: "The resolved address does not match its configuration."),
                        systemImage: "arrow.trianglehead.branch",
                        tint: .orange
                    )
                )
            case let .failed(detail):
                items.append(
                    OverviewAttentionItem(
                        id: "\(domain.id)-failed",
                        title: domain.domain,
                        detail: detail,
                        systemImage: "xmark.circle.fill",
                        tint: .red
                    )
                )
            }
        }

        return items
    }

    private var hasCriticalIssue: Bool {
        guard environmentStatus.isReady else { return true }
        return enabledDomains.contains { domain in
            switch healthResults[domain.id] {
            case .noAnswer, .failed:
                true
            default:
                false
            }
        }
    }

    private var recentDomains: [LocalDomain] {
        domains.sorted { lhs, rhs in
            let lhsNeedsAttention = healthResults[lhs.id]?.needsAttention == true
            let rhsNeedsAttention = healthResults[rhs.id]?.needsAttention == true
            if lhsNeedsAttention != rhsNeedsAttention {
                return lhsNeedsAttention
            }
            return lhs.domain.localizedStandardCompare(rhs.domain) == .orderedAscending
        }
    }

    private var healthCheckKey: String {
        let domainKey = domains.map {
            [$0.id.uuidString, $0.domain, $0.address, String($0.wildcard), String($0.enabled)]
                .joined(separator: ":")
        }.joined(separator: "|")
        return "\(refreshRevision)-\(domainKey)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                healthSection
                statusGrid
                workspaceGrid
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: healthCheckKey) {
            await checkDomainHealth()
        }
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

            Button(action: refreshDashboard) {
                HStack(spacing: 7) {
                    if isCheckingHealth {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
            }
            .disabled(isCheckingHealth)

            Button(action: onAddDomain) {
                Label("Add domain", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var healthSection: some View {
        let presentation = healthPresentation

        return VStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: presentation.systemImage)
                    .font(.title2)
                    .foregroundStyle(presentation.tint)
                    .frame(width: 42, height: 42)
                    .background(presentation.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.headline)
                    Text(presentation.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onRestart) {
                    Label("Restart dnsmasq", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!environmentStatus.isReady)
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(presentation.tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(presentation.tint.opacity(0.24), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var statusGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                attentionSection.frame(minWidth: 320)
                environmentSection.frame(minWidth: 320)
            }
            VStack(spacing: 18) {
                attentionSection
                environmentSection
            }
        }
    }

    @ViewBuilder
    private var workspaceGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                domainsSection.frame(minWidth: 430)
                configurationSection.frame(minWidth: 300)
            }
            VStack(spacing: 18) {
                domainsSection
                configurationSection
            }
        }
    }

    private var attentionSection: some View {
        OverviewSection(title: "Needs attention", systemImage: "exclamationmark.triangle") {
            Group {
                if isCheckingHealth && attentionItems.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Checking enabled domains…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 122, alignment: .center)
                } else if attentionItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("No issues detected")
                            .font(.headline)
                        Text("All enabled domains resolve correctly.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 122, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(attentionItems.prefix(3).enumerated()), id: \.element.id) { index, item in
                            OverviewAttentionRow(item: item)
                            if index < min(attentionItems.count, 3) - 1 {
                                Divider()
                            }
                        }
                        if attentionItems.count > 3 {
                            Button(
                                String(localized: "View all \(attentionItems.count) issues"),
                                action: onShowDomains
                            )
                            .controlSize(.small)
                            .padding(.top, 10)
                        }
                    }
                }
            }
            .frame(minHeight: 170, alignment: .top)
        }
    }

    private var environmentSection: some View {
        OverviewSection(
            title: "Environment",
            systemImage: "wrench.and.screwdriver",
            actionTitle: "View details",
            action: onShowEnvironment
        ) {
            VStack(spacing: 0) {
                OverviewEnvironmentRow(
                    title: "Homebrew",
                    detail: environmentStatus.homebrew.path
                        ?? String(localized: "Not found"),
                    isReady: environmentStatus.homebrew.isAvailable
                )
                Divider()
                OverviewEnvironmentRow(
                    title: "dnsmasq",
                    detail: environmentStatus.dnsmasq.path
                        ?? String(localized: "Not found"),
                    isReady: environmentStatus.dnsmasq.isAvailable
                )
                Divider()
                OverviewEnvironmentRow(
                    title: "Privileged helper",
                    detail: helperController.state.title,
                    isReady: helperController.state.isReady,
                    isChecking: helperController.state == .checking
                )
            }
            .frame(minHeight: 170, alignment: .top)
        }
    }

    private var domainsSection: some View {
        OverviewSection(
            title: "Recent domains",
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
                .frame(minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentDomains.prefix(5).enumerated()), id: \.element.id) { index, domain in
                        OverviewDomainRow(
                            domain: domain,
                            result: healthResults[domain.id],
                            isChecking: isCheckingHealth
                        )

                        if index < min(recentDomains.count, 5) - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var configurationSection: some View {
        OverviewSection(
            title: "Configuration",
            systemImage: "doc.text",
            actionTitle: configurationSources.compactMap(\.path).isEmpty ? nil : "Show in Finder",
            action: revealConfiguration
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 22) {
                    OverviewConfigurationMetric(value: configurationSources.count, title: "Files")
                    OverviewConfigurationMetric(value: domains.count, title: "Mappings")
                }

                Divider()

                VStack(alignment: .leading, spacing: 5) {
                    Text("Configuration directory")
                        .font(.caption.weight(.medium))
                    Text(configurationDirectory)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !configurationSources.isEmpty {
                    Divider()
                    VStack(spacing: 7) {
                        ForEach(configurationSources.prefix(3)) { source in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(source.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(source.count, format: .number)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        if configurationSources.count > 3 {
                            Text(String(localized: "+\(configurationSources.count - 3) more files"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(minHeight: 180, alignment: .top)
        }
    }

    private var healthPresentation: OverviewHealthPresentation {
        if isCheckingHealth || helperController.state == .checking {
            return OverviewHealthPresentation(
                title: String(localized: "Checking local DNS…"),
                detail: String(localized: "Testing dnsmasq, system resolvers and secure access."),
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                tint: .blue
            )
        }
        if attentionItems.isEmpty {
            let detail = enabledDomains.count == 1
                ? String(localized: "1 active mapping resolves correctly.")
                : String(localized: "\(enabledDomains.count) active mappings resolve correctly.")
            return OverviewHealthPresentation(
                title: String(localized: "Everything is working"),
                detail: detail,
                systemImage: "checkmark.shield.fill",
                tint: .green
            )
        }
        let title = attentionItems.count == 1
            ? String(localized: "1 item needs attention")
            : String(localized: "\(attentionItems.count) items need attention")
        return OverviewHealthPresentation(
            title: title,
            detail: String(localized: "Review the issues below to restore complete local DNS coverage."),
            systemImage: "exclamationmark.triangle.fill",
            tint: hasCriticalIssue ? .red : .orange
        )
    }

    private func refreshDashboard() {
        onCheckEnvironment()
        onRefresh()
        refreshRevision &+= 1
    }

    private func revealConfiguration() {
        guard let path = configurationSources.compactMap(\.path).first else { return }
        onRevealFile(path)
    }

    private func checkDomainHealth() async {
        isCheckingHealth = true
        let snapshot = domains
        var collected: [UUID: DomainResolutionTestResult] = [:]

        await withTaskGroup(of: (UUID, DomainResolutionTestResult).self) { group in
            for domain in snapshot {
                group.addTask {
                    (domain.id, await DnsmasqDomainTester().check(domain))
                }
            }
            for await (id, result) in group {
                collected[id] = result
            }
        }

        guard !Task.isCancelled else { return }
        healthResults = collected
        isCheckingHealth = false
    }
}

private struct OverviewConfigurationSource: Identifiable {
    var id: String { path ?? name }
    let path: String?
    let name: String
    let count: Int
}

private struct OverviewAttentionItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
}

private struct OverviewHealthPresentation {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
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

private struct OverviewAttentionRow: View {
    let item: OverviewAttentionItem

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .fontWeight(.medium)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }
}

private struct OverviewEnvironmentRow: View {
    let title: LocalizedStringResource
    let detail: String
    let isReady: Bool
    var isChecking = false

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(isReady ? .green : .red)
                }
            }
            .frame(width: 20)

            Text(title)
                .fontWeight(.medium)
            Spacer(minLength: 10)
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
    }
}

private struct OverviewConfigurationMetric: View {
    let value: Int
    let title: LocalizedStringResource

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverviewDomainRow: View {
    let domain: LocalDomain
    let result: DomainResolutionTestResult?
    let isChecking: Bool

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

            Spacer(minLength: 12)

            Text(domain.address)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            OverviewHealthBadge(
                isEnabled: domain.enabled,
                result: result,
                isChecking: isChecking
            )
        }
        .padding(.vertical, 10)
    }
}

private struct OverviewHealthBadge: View {
    let isEnabled: Bool
    let result: DomainResolutionTestResult?
    let isChecking: Bool

    var body: some View {
        Group {
            if !isEnabled {
                Label("Off", systemImage: "pause.circle.fill")
                    .foregroundStyle(.secondary)
            } else if isChecking && result == nil {
                ProgressView().controlSize(.small)
            } else {
                switch result {
                case .active:
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .mdnsConflict:
                    Label("Bonjour", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .notRouted:
                    Label("Resolver", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .noAnswer, .failed:
                    Label("Failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .mismatch:
                    Label("Mismatch", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .disabled:
                    Label("Off", systemImage: "pause.circle.fill")
                        .foregroundStyle(.secondary)
                case nil:
                    Text("—").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption.weight(.medium))
        .fixedSize()
    }
}

private extension DomainResolutionTestResult {
    var needsAttention: Bool {
        switch self {
        case .active, .disabled:
            false
        default:
            true
        }
    }
}
