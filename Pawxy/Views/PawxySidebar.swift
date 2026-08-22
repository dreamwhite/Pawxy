//
//  PawxySidebar.swift
//  Pawxy
//

import SwiftUI

enum SidebarDestination: String, Hashable {
    case overview
    case domains
    case environment
}

struct PawxySidebar: View {
    @Binding var destination: SidebarDestination?
    let environmentStatus: DevelopmentEnvironmentStatus

    var body: some View {
        List(selection: $destination) {
            Section("Pawxy") {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarDestination.overview)
            }

            Section("DNS") {
                Label("Local Domains", systemImage: "globe")
                    .tag(SidebarDestination.domains)

                Label("Environment", systemImage: "wrench.and.screwdriver")
                    .tag(SidebarDestination.environment)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Pawxy")
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        .safeAreaInset(edge: .bottom) {
            environmentFooter
        }
    }

    private var environmentFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(environmentStatus.isReady ? Color.green : Color.red)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(environmentStatus.isReady
                     ? String(localized: "Environment ready")
                     : String(localized: "Setup required"))
                    .font(.caption.weight(.medium))
                Text("Homebrew + dnsmasq")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(.bar)
    }
}
