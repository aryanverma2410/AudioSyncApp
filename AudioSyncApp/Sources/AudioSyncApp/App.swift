import SwiftUI

@main
struct AudioSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    init() {
        // Initialize the diagnostic logger on app launch
        DLog("AudioSyncApp launched (bundle: \(Bundle.main.bundleIdentifier ?? "unknown"))")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandMenu("Playback") {
                Button("Start Routing") {
                    Task { await appState.start() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Stop Routing") {
                    appState.stop()
                }
                .keyboardShortcut(".", modifiers: .command)

                Divider()

                Button("Refresh Devices") {
                    appState.deviceDiscovery.refreshDevices()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
