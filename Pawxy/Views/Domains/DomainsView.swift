//
//  DomainsView.swift
//  Pawxy
//

import SwiftUI

struct DomainsView: View {
    @ObservedObject var store: DomainStore
    @Binding var searchText: String
    let updatingDomainIDs: Set<UUID>
    let healthCheckRevision: Int

    let onAdd: () -> Void
    let onRefresh: () -> Void
    let onImportBackup: () -> Void
    let onExportBackup: () -> Void
    let onShowInFinder: (LocalDomain) -> Void
    let onRepairResolver: (LocalDomain) -> Void
    let onEdit: (LocalDomain) -> Void
    let onDelete: (LocalDomain) -> Void
    let onSetEnabled: (Bool, LocalDomain) -> Void

    private var filteredDomains: [LocalDomain] {
        guard !searchText.isEmpty else { return store.domains }
        return store.domains.filter {
            $0.domain.localizedCaseInsensitiveContains(searchText)
                || $0.address.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            searchField
            domainContent

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Local Domains")
                    .font(.largeTitle.bold())
                Text("Create and manage dnsmasq development hostnames.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Menu {
                Button("Import Backup…", systemImage: "square.and.arrow.down", action: onImportBackup)
                Button("Export Backup…", systemImage: "square.and.arrow.up", action: onExportBackup)
            } label: {
                Label("Backup", systemImage: "archivebox")
            }

            Button(action: onAdd) {
                Label("Add domain", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search domains or addresses", text: $searchText)
                .textFieldStyle(.plain)
            Text(resultCountText)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private var resultCountText: String {
        filteredDomains.count == 1
            ? String(localized: "1 result")
            : String(localized: "\(filteredDomains.count) results")
    }

    @ViewBuilder
    private var domainContent: some View {
        if filteredDomains.isEmpty {
            ContentUnavailableView {
                Label(
                    searchText.isEmpty
                        ? String(localized: "No local domains")
                        : String(localized: "No results"),
                    systemImage: searchText.isEmpty ? "globe.badge.chevron.backward" : "magnifyingglass"
                )
            } description: {
                Text(searchText.isEmpty
                     ? String(localized: "No supported mappings were found in dnsmasq.")
                     : String(localized: "Try a different domain or address."))
            } actions: {
                if searchText.isEmpty {
                    HStack {
                        Button("Refresh mappings", action: onRefresh)
                        Button("Add domain", action: onAdd)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredDomains) { domain in
                        DomainRow(
                            domain: domain,
                            isUpdating: updatingDomainIDs.contains(domain.id),
                            healthCheckRevision: healthCheckRevision,
                            onSetEnabled: { onSetEnabled($0, domain) },
                            onShowInFinder: { onShowInFinder(domain) },
                            onRepairResolver: { onRepairResolver(domain) },
                            onEdit: { onEdit(domain) },
                            onDelete: { onDelete(domain) }
                        )
                    }
                }
                .padding(1)
            }
            .id(searchText)
        }
    }
}

private struct DomainRow: View {
    let domain: LocalDomain
    let isUpdating: Bool
    let healthCheckRevision: Int
    let onSetEnabled: (Bool) -> Void
    let onShowInFinder: () -> Void
    let onRepairResolver: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isTestingResolution = false
    @State private var resolutionResult: DomainResolutionTestResult?

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: domain.wildcard ? "network" : "globe")
                .foregroundStyle(domain.enabled ? .blue : .secondary)
                .frame(width: 24, height: 24)

            domainDetails
            Spacer(minLength: 16)

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 36)
            } else {
                resolutionTestControl
            }

            Toggle(
                domain.enabled ? String(localized: "On") : String(localized: "Off"),
                isOn: Binding(get: { domain.enabled }, set: onSetEnabled)
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .disabled(isUpdating)

            actionMenu
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
        .onChange(of: domain.enabled) { _, _ in
            resolutionResult = nil
        }
        .task(id: automaticTestKey) {
            await runResolutionTest()
        }
    }

    private var resolutionTestControl: some View {
        Button(action: testResolution) {
            Group {
                if isTestingResolution {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else if let resolutionResult {
                    resolutionLabel(for: resolutionResult)
                } else {
                    Label("Test", systemImage: "wave.3.right")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(isTestingResolution)
        .help(resolutionHelpText)
        .fixedSize()
    }

    @ViewBuilder
    private func resolutionLabel(for result: DomainResolutionTestResult) -> some View {
        switch result {
        case .active:
            Label("Active", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .disabled:
            Label("Disabled", systemImage: "pause.circle.fill")
                .foregroundStyle(.secondary)
        case .noAnswer:
            Label("No answer", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .notRouted:
            Label("Resolver missing", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .mdnsConflict:
            Label("Bonjour conflict", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .mismatch:
            Label("Mismatch", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var resolutionHelpText: String {
        guard let resolutionResult else {
            return String(localized: "Verify this mapping through dnsmasq and the macOS system resolver.")
        }

        switch resolutionResult {
        case let .active(hostname, address):
            return String(localized: "\(hostname) resolves to \(address) through dnsmasq. Click to test again.")
        case .disabled:
            return String(localized: "This mapping is disabled. Enable it before testing resolution.")
        case let .noAnswer(hostname):
            return String(localized: "dnsmasq returned no IPv4 address for \(hostname). Click to test again.")
        case let .notRouted(hostname, expected):
            return String(localized: "dnsmasq resolves \(hostname) to \(expected), but macOS is not routing the domain to dnsmasq. Use Repair system resolver, then test again.")
        case let .mdnsConflict(domain):
            return String(localized: "\(domain) uses .local, which macOS reserves for Bonjour/mDNS. Use a suffix such as .pawxy or .test.")
        case let .mismatch(hostname, expected, received):
            let receivedAddresses = received.joined(separator: ", ")
            return String(localized: "\(hostname) should resolve to \(expected), but dnsmasq returned \(receivedAddresses). Click to test again.")
        case let .failed(detail):
            return String(localized: "\(detail) Click to test again.")
        }
    }

    private func testResolution() {
        Task {
            await runResolutionTest()
        }
    }

    private var automaticTestKey: String {
        [
            domain.domain,
            domain.address,
            String(domain.wildcard),
            String(domain.enabled),
            String(healthCheckRevision)
        ].joined(separator: "|")
    }

    private func runResolutionTest() async {
        guard !isTestingResolution else { return }
        isTestingResolution = true
        resolutionResult = await DnsmasqDomainTester().check(domain)
        isTestingResolution = false
    }

    private var domainDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(domain.domain)
                .font(.headline)

            HStack(spacing: 6) {
                Text(domain.address)
                    .font(.caption.monospaced())
                Text("·")
                Text(domain.wildcard
                     ? String(localized: "DNS zone")
                     : String(localized: "Exact record"))
                Text("·")
                Text(domain.origin.label)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var actionMenu: some View {
        Menu {
            if case .imported = domain.origin {
                Button("Show in Finder", systemImage: "folder", action: onShowInFinder)
                Divider()
            }
            Button(
                "Repair system resolver…",
                systemImage: "network.badge.shield.half.filled",
                action: onRepairResolver
            )
            .disabled(!domain.enabled || isUpdating || domain.domain.lowercased().hasSuffix(".local"))
            Divider()
            Button("Edit…", systemImage: "pencil", action: onEdit)
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
