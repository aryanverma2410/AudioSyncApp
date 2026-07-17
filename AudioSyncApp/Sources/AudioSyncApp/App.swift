import SwiftUI

@main
struct AudioSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Shared instances — created once, shared across all views
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var profileManager = AudioProfileManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioEngine)
                .environmentObject(deviceManager)
                .environmentObject(profileManager)
                .frame(minWidth: 900, minHeight: 650)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandMenu("Playback") {
                Button("Play") {
                    audioEngine.load(url: nil)
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Pause") {
                    audioEngine.pause()
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Stop") {
                    audioEngine.stop()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("Devices") {
                Button("Refresh Devices") {
                    deviceManager.refreshDevices()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        // Settings window
        Settings {
            AppSettingsView()
                .environmentObject(audioEngine)
                .environmentObject(deviceManager)
                .environmentObject(profileManager)
        }
    }
}
