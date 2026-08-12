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
                .background {
                    WindowAccessor { window in
                        window.setFrameAutosaveName("AudioSyncMainWindow")
                    }
                }
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

// MARK: - Window Accessor (for NSWindow frame persistence)

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window {
                self.callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                self.callback(window)
            }
        }
    }
}
