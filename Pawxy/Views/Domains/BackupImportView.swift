//
//  BackupImportView.swift
//  Pawxy
//

import SwiftUI

struct BackupImportView: View {
    @Environment(\.dismiss) private var dismiss

    let backup: PawxyConfigurationBackup
    let filename: String
    let existingDomainNames: Set<String>
    let onImport: ([LocalDomain]) async throws -> Void

    @State private var selectedNames: Set<String>
    @State private var importError: String?
    @State private var isImporting = false

    init(
        backup: PawxyConfigurationBackup,
        filename: String,
        existingDomainNames: Set<String>,
        onImport: @escaping ([LocalDomain]) async throws -> Void
    ) {
        self.backup = backup
        self.filename = filename
        self.existingDomainNames = existingDomainNames
        self.onImport = onImport

        _selectedNames = State(initialValue: Set(
            backup.mappings
                .filter { !existingDomainNames.contains($0.domain.lowercased()) }
                .map { $0.domain.lowercased() }
        ))
    }

    private var selectedMappings: [PawxyConfigurationBackup.Mapping] {
        backup.mappings.filter { selectedNames.contains($0.domain.lowercased()) }
    }

    private var conflictCount: Int {
        backup.mappings.count - backup.mappings.filter {
            !existingDomainNames.contains($0.domain.lowercased())
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            mappingList
            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .alert("Could not import backup", isPresented: errorBinding) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox.fill")
                .font(.title)
                .foregroundStyle(.blue)
                .frame(width: 48, height: 48)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("Import Pawxy backup")
                    .font(.title2.bold())
                Text(filename)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(mappingCountText)
                    .fontWeight(.medium)
                Text(backup.exportedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
    }

    private var mappingCountText: String {
        backup.mappings.count == 1
            ? String(localized: "1 mapping")
            : String(localized: "\(backup.mappings.count) mappings")
    }

    private var mappingList: some View {
        Group {
            if backup.mappings.isEmpty {
                ContentUnavailableView(
                    "Empty backup",
                    systemImage: "archivebox",
                    description: Text("This backup does not contain any domain mappings.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(backup.mappings) { mapping in
                            BackupMappingRow(
                                mapping: mapping,
                                isConflict: existingDomainNames.contains(mapping.domain.lowercased()),
                                isSelected: Binding(
                                    get: { selectedNames.contains(mapping.domain.lowercased()) },
                                    set: { selected in
                                        if selected {
                                            selectedNames.insert(mapping.domain.lowercased())
                                        } else {
                                            selectedNames.remove(mapping.domain.lowercased())
                                        }
                                    }
                                )
                            )

                            if mapping.id != backup.mappings.last?.id {
                                Divider().padding(.leading, 50)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Each new mapping gets its own dnsmasq .conf file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if conflictCount > 0 {
                    Text(conflictCount == 1
                         ? String(localized: "1 existing domain is skipped.")
                         : String(localized: "\(conflictCount) existing domains are skipped."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                performImport()
            } label: {
                HStack(spacing: 6) {
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isImporting
                         ? String(localized: "Importing…")
                         : String(localized: "Import \(selectedMappings.count)"))
                }
            }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedMappings.isEmpty || isImporting)
        }
        .padding(16)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )
    }

    private func performImport() {
        guard !isImporting else { return }
        isImporting = true
        Task {
            do {
                try await onImport(selectedMappings.map(\.localDomain))
                dismiss()
            } catch {
                importError = error.localizedDescription
            }
            isImporting = false
        }
    }
}

private struct BackupMappingRow: View {
    let mapping: PawxyConfigurationBackup.Mapping
    let isConflict: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .disabled(isConflict)

            Image(systemName: mapping.wildcard ? "network" : "globe")
                .foregroundStyle(isConflict ? Color.secondary : Color.blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(mapping.domain)
                    .fontWeight(.medium)
                Text(mappingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isConflict {
                Label("Already exists", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isConflict else { return }
            isSelected.toggle()
        }
    }

    private var mappingSummary: String {
        let coverage = mapping.wildcard
            ? String(localized: "DNS zone")
            : String(localized: "Exact record")
        let status = mapping.enabled
            ? String(localized: "Enabled")
            : String(localized: "Disabled")
        return "\(mapping.address) · \(coverage) · \(status)"
    }
}
