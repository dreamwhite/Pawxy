//
//  DomainsView.swift
//  Pawxy
//

import SwiftUI

struct DomainsView: View {
    let domains: [LocalDomain]
    let storeError: String?
    @Binding var searchText: String
    let isRefreshing: Bool
    let updatingDomainIDs: Set<UUID>
    let pendingDomainIDs: Set<UUID>
    let healthCheckRevision: Int

    @State private var healthResults: [UUID: DomainResolutionTestResult] = [:]
    @State private var testingDomainIDs = Set<UUID>()

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
        guard !searchText.isEmpty else { return domains }
        return domains.filter {
            $0.domain.localizedCaseInsensitiveContains(searchText)
                || $0.address.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            searchField
            domainContent

            if let error = storeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: automaticHealthCheckKey) {
            await checkDomainHealth()
        }
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
                if isRefreshing {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing…")
                    }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing)

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
                            isPending: pendingDomainIDs.contains(domain.id),
                            isTestingResolution: testingDomainIDs.contains(domain.id),
                            resolutionResult: healthResults[domain.id],
                            onTestResolution: { testResolution(domain) },
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

    private var automaticHealthCheckKey: String {
        let domainKey = domains.map {
            "\($0.id)|\($0.domain)|\($0.address)|\($0.wildcard)|\($0.enabled)"
        }.joined(separator: ";")
        return "\(healthCheckRevision)|\(domainKey)|\(pendingDomainIDs.count)"
    }

    private func checkDomainHealth() async {
        let testableDomains = domains.filter {
            guard !pendingDomainIDs.contains($0.id) else { return false }
            if case .conflict = $0.origin { return false }
            return true
        }
        testingDomainIDs = Set(testableDomains.map(\.id))
        let results = await DomainHealthCheckService().check(testableDomains)
        guard !Task.isCancelled else { return }
        healthResults = results
        testingDomainIDs.removeAll()
    }

    private func testResolution(_ domain: LocalDomain) {
        guard !pendingDomainIDs.contains(domain.id),
              !testingDomainIDs.contains(domain.id)
        else { return }
        testingDomainIDs.insert(domain.id)
        Task {
            let result = await DnsmasqDomainTester().check(domain)
            guard !Task.isCancelled else { return }
            healthResults[domain.id] = result
            testingDomainIDs.remove(domain.id)
        }
    }
}

private struct DomainRow: View {
    let domain: LocalDomain
    let isUpdating: Bool
    let isPending: Bool
    let isTestingResolution: Bool
    let resolutionResult: DomainResolutionTestResult?
    let onTestResolution: () -> Void
    let onSetEnabled: (Bool) -> Void
    let onShowInFinder: () -> Void
    let onRepairResolver: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

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
            .disabled(isUpdating || isConflict)

            actionMenu
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private var resolutionTestControl: some View {
        Button(action: testResolution) {
            Group {
                if isTestingResolution {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else if isPending {
                    Label("Pending", systemImage: "clock.badge")
                        .foregroundStyle(.blue)
                } else if isConflict {
                    Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
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
        .disabled(isTestingResolution || isPending || isConflict)
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
        if isPending {
            return String(localized: "This domain has unapplied changes. Apply them before testing resolution.")
        }
        if case let .conflict(sources) = domain.origin {
            return String(localized: "Multiple dnsmasq directives define this domain: \(sources.map(\.label).joined(separator: ", ")). Resolve them in the source files first.")
        }
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
        onTestResolution()
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
                    .foregroundStyle(isConflict ? .orange : .secondary)
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
            .disabled(
                !domain.enabled
                    || isUpdating
                    || isConflict
                    || domain.domain.lowercased().hasSuffix(".local")
            )
            Divider()
            Button("Edit…", systemImage: "pencil", action: onEdit)
                .disabled(isConflict)
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(isConflict)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var isConflict: Bool {
        if case .conflict = domain.origin { return true }
        return false
    }
}
