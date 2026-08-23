//
//  ConflictResolutionView.swift
//  Pawxy
//

import AppKit
import SwiftUI

struct ConflictResolutionView: View {
    @Environment(\.dismiss) private var dismiss

    let domain: LocalDomain
    let onSelect: (DomainDirectiveSource) -> Void

    private var sources: [DomainDirectiveSource] {
        guard case let .conflict(sources) = domain.origin else { return [] }
        return sources
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(sources, id: \.self) { source in
                        sourceRow(source)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("The selected directive will remain unchanged. Pawxy will remove the duplicates in the same reviewed transaction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 720, height: 500)
    }

    private var header: some View {
        HStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 48, height: 48)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 3) {
                Text("Resolve \(domain.domain)")
                    .font(.title2.bold())
                Text("Choose the dnsmasq directive that should remain active.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private func sourceRow(_ source: DomainDirectiveSource) -> some View {
        HStack(spacing: 14) {
            Image(systemName: source.wildcard ? "network" : "globe")
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(source.label)
                    .font(.headline)
                HStack(spacing: 7) {
                    Text(source.address.isEmpty ? domain.address : source.address)
                        .monospaced()
                    Text("·")
                    Text(source.wildcard ? "Domain and subdomains" : "Exact domain")
                    Text("·")
                    Text(source.enabled ? "Enabled" : "Disabled")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(source.file)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: source.file)
                ])
            } label: {
                Image(systemName: "folder")
            }
            .help("Show in Finder")

            Button("Keep This Directive") {
                onSelect(source)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }
}
