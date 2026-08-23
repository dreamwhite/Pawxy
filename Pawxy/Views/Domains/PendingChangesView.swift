//
//  PendingChangesView.swift
//  Pawxy
//

import SwiftUI

struct PendingChangesView: View {
    @Environment(\.dismiss) private var dismiss

    let changes: [PendingDomainChange]
    let isApplying: Bool
    let onApply: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            changeList
            Divider()
            actions
        }
        .frame(width: 680, height: 520)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 48, height: 48)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 3) {
                Text("Pending DNS changes")
                    .font(.title2.bold())
                Text("Review everything Pawxy will apply with one administrator authorization and one dnsmasq restart.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var changeList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(changes) { change in
                    PendingChangeRow(change: change)
                }
            }
            .padding(20)
        }
    }

    private var actions: some View {
        HStack {
            Button("Discard All", role: .destructive) {
                onDiscard()
                dismiss()
            }
            .disabled(isApplying)

            Spacer()

            Button("Not Now") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)

            Button {
                onApply()
            } label: {
                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 100)
                } else {
                    Text("Apply Changes")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(changes.isEmpty || isApplying)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct PendingChangeRow: View {
    let change: PendingDomainChange

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(kind)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private var title: String {
        switch change {
        case let .add(domain), let .delete(domain):
            domain.domain
        case let .update(original, updated):
            original.domain == updated.domain
                ? updated.domain
                : "\(original.domain) → \(updated.domain)"
        }
    }

    private var detail: String {
        switch change {
        case let .add(domain):
            return "\(domain.address) · \(coverage(domain)) · \(state(domain))"
        case .delete:
            return String(localized: "Remove its dnsmasq directive and managed resolver.")
        case let .update(original, updated):
            let before = "\(original.address), \(coverage(original)), \(state(original))"
            let after = "\(updated.address), \(coverage(updated)), \(state(updated))"
            return "\(before) → \(after)"
        }
    }

    private var kind: String {
        switch change {
        case .add: String(localized: "Add")
        case .update: String(localized: "Change")
        case .delete: String(localized: "Delete")
        }
    }

    private var systemImage: String {
        switch change {
        case .add: "plus.circle.fill"
        case .update: "pencil.circle.fill"
        case .delete: "trash.circle.fill"
        }
    }

    private var tint: Color {
        switch change {
        case .add: .green
        case .update: .blue
        case .delete: .red
        }
    }

    private func coverage(_ domain: LocalDomain) -> String {
        domain.wildcard
            ? String(localized: "Domain and subdomains")
            : String(localized: "Exact domain")
    }

    private func state(_ domain: LocalDomain) -> String {
        domain.enabled ? String(localized: "Enabled") : String(localized: "Disabled")
    }
}
