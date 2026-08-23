//
//  PawxyApp.swift
//  Pawxy
//
//  Created by Ivan Cafiero on 22/08/2026.
//

import SwiftUI

@main
struct PawxyApp: App {
    @StateObject private var domainStore = DomainStore()
    @StateObject private var softwareUpdates = SoftwareUpdateController()
    @StateObject private var activityLog = ActivityLogStore()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        Window("Pawxy", id: "pawxy-main") {
            AppRootView()
                .environmentObject(domainStore)
                .environmentObject(softwareUpdates)
                .environmentObject(activityLog)
        }
        .commands {
            PawxyCommands(softwareUpdates: softwareUpdates)
        }

        Settings {
            SettingsView()
                .environmentObject(softwareUpdates)
        }

        Window("About Pawxy", id: "pawxy-about") {
            AboutView()
                .environmentObject(softwareUpdates)
        }
        .defaultPosition(.center)
        .windowResizability(.contentSize)

        Window("Pawxy Help", id: "pawxy-help") {
            HelpView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra(
            "Pawxy",
            systemImage: "pawprint.fill",
            isInserted: $showMenuBarExtra
        ) {
            PawxyMenuBarView()
                .environmentObject(domainStore)
                .environmentObject(activityLog)
        }
        .menuBarExtraStyle(.menu)
    }
}

extension Notification.Name {
    static let showPawxyOverview = Notification.Name("showPawxyOverview")
    static let addPawxyDomain = Notification.Name("addPawxyDomain")
    static let refreshPawxyMappings = Notification.Name("refreshPawxyMappings")
    static let restartPawxyDnsmasq = Notification.Name("restartPawxyDnsmasq")
    static let importPawxyBackup = Notification.Name("importPawxyBackup")
    static let exportPawxyBackup = Notification.Name("exportPawxyBackup")
}

private struct PawxyCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var softwareUpdates: SoftwareUpdateController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Pawxy") {
                openWindow(id: "pawxy-about")
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                softwareUpdates.checkForUpdates()
            }
            .disabled(!softwareUpdates.canCheckForUpdates)

            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Button("New Domain") {
                NotificationCenter.default.post(name: .addPawxyDomain, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("Refresh Mappings") {
                NotificationCenter.default.post(name: .refreshPawxyMappings, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Restart dnsmasq…") {
                NotificationCenter.default.post(name: .restartPawxyDnsmasq, object: nil)
            }

            Divider()

            Button("Import Backup…") {
                NotificationCenter.default.post(name: .importPawxyBackup, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Export Backup…") {
                NotificationCenter.default.post(name: .exportPawxyBackup, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Pawxy Help") {
                openWindow(id: "pawxy-help")
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
