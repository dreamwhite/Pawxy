//
//  DomainEditorView.swift
//  Pawxy
//

import SwiftUI

struct DomainEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let domain: LocalDomain?
    let existingDomains: [LocalDomain]
    let onSave: (LocalDomain) async throws -> Void

    @State private var draft: LocalDomainDraft
    @State private var saveError: String?
    @State private var isSaving = false

    init(
        domain: LocalDomain?,
        existingDomains: [LocalDomain],
        defaultAddress: String,
        onSave: @escaping (LocalDomain) async throws -> Void
    ) {
        self.domain = domain
        self.existingDomains = existingDomains
        self.onSave = onSave

        if let domain {
            _draft = State(initialValue: LocalDomainDraft(domain: domain))
        } else {
            var draft = LocalDomainDraft()
            draft.address = defaultAddress
            _draft = State(initialValue: draft)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editorForm
            Divider()
            actions
        }
        .frame(width: 640, height: 520)
        .alert(
            "Could not update dnsmasq",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: domain == nil ? "plus.circle.fill" : "pencil.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 52, height: 52)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text(domain == nil
                     ? String(localized: "Add local domain")
                     : String(localized: "Edit local domain"))
                    .font(.title2.bold())
                Text("Configure a hostname mapping for local development.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    private var editorForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Mapping") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                        GridRow {
                            Text("Domain")
                                .foregroundStyle(.secondary)
                            TextField(
                                "Domain",
                                text: $draft.domain,
                                prompt: Text("my-project.test")
                            )
                            .textFieldStyle(.roundedBorder)
                        }

                        GridRow {
                            Text("IPv4 address")
                                .foregroundStyle(.secondary)
                            TextField("IPv4 address", text: $draft.address)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospaced())
                        }
                    }
                    .gridColumnAlignment(.leading)
                    .padding(10)
                }

                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Enable this domain", isOn: $draft.enabled)

                        Divider()

                        Picker("Coverage", selection: $draft.wildcard) {
                            Text("Exact domain").tag(false)
                            Text("Domain and subdomains").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(10)
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                    Text("Pawxy validates the mapping, updates the dnsmasq configuration and macOS resolver, then restarts the service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button {
                save()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 76)
                } else {
                    Text(domain == nil
                         ? String(localized: "Add domain")
                         : String(localized: "Save changes"))
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave || isSaving)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var canSave: Bool {
        !draft.normalizedDomain.isEmpty && validationMessage == nil
    }

    private var validationMessage: String? {
        if draft.domain.isEmpty { return nil }
        if let message = draft.validationMessage { return message }

        if domain == nil, draft.normalizedDomain.hasSuffix(".local") {
            return String(localized: "macOS reserves .local for Bonjour. Use a suffix such as .pawxy or .test.")
        }

        if existingDomains.contains(where: {
            $0.id != domain?.id
                && $0.domain.caseInsensitiveCompare(draft.normalizedDomain) == .orderedSame
        }) {
            return String(localized: "This domain already exists.")
        }
        return nil
    }

    private func save() {
        let savedDomain: LocalDomain?
        if let domain {
            savedDomain = draft.updating(domain)
        } else {
            savedDomain = draft.localDomain
        }

        guard let savedDomain else { return }
        isSaving = true
        Task {
            do {
                try await onSave(savedDomain)
                dismiss()
            } catch {
                saveError = error.localizedDescription
                isSaving = false
            }
        }
    }
}

#Preview("Add domain") {
    DomainEditorView(
        domain: nil,
        existingDomains: [],
        defaultAddress: "127.0.0.1"
    ) { _ in }
}
