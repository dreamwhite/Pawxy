//
//  ActivityLogView.swift
//  Pawxy
//

import AppKit
import SwiftUI

struct ActivityLogView: View {
    @EnvironmentObject private var activityLog: ActivityLogStore

    let environmentStatus: DevelopmentEnvironmentStatus
    let domains: [LocalDomain]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if activityLog.entries.isEmpty {
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("DNS changes, resolver repairs, restarts and backups will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(activityLog.entries) { entry in
                            ActivityLogRow(entry: entry)
                            if entry.id != activityLog.entries.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.separator.opacity(0.6), lineWidth: 1)
                    }
                }
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.largeTitle.bold())
                Text("A local history of Pawxy operations and failures.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let report = PawxyDiagnosticsService().report(
                    status: environmentStatus,
                    domains: domains,
                    recentActivity: activityLog.entries
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
                activityLog.record(
                    .diagnostics,
                    title: String(localized: "Diagnostics copied")
                )
            } label: {
                Label("Copy Diagnostics", systemImage: "doc.on.doc")
            }

            Button("Clear", role: .destructive) {
                activityLog.clear()
            }
            .disabled(activityLog.entries.isEmpty)
        }
    }
}
private struct ActivityLogRow: View {
    let entry: ActivityLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(entry.succeeded ? .green : .red)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.title)
                        .font(.headline)
                    Spacer()
                    Text(entry.date, format: .dateTime.day().month().hour().minute().second())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 11)
    }
}
