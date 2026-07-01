import Cocoa
import SwiftUI
import ServiceManagement

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up menu bar item
        setupMenuBarItem()


        // Set activation policy
        NSApp.setActivationPolicy(.regular)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up menu bar item
        statusItem = nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu Bar Item

        // FIXME: Add sample rate validation check
    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "AudioSync")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Open AudioSync", action: #selector(openWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Start Routing", action: #selector(startRouting), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Stop Routing", action: #selector(stopRouting), keyEquivalent: "."))
        menu.addItem(NSMenuItem.separator())

        // Launch at Login toggle
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
    }

    // MARK: - Launch at Login

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if launchAtLoginEnabled {
            try? SMAppService.mainApp.unregister()
            sender.state = .off
            DLog("[AppDelegate] Launch at Login disabled")
        } else {
            do {
                try SMAppService.mainApp.register()
                sender.state = .on
                DLog("[AppDelegate] Launch at Login enabled")

            } catch {
                DLog("[AppDelegate] Failed to enable Launch at Login: \(error)")
            }
        }
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func startRouting() {
        // Post notification for AppState to handle
        NotificationCenter.default.post(name: .startRouting, object: nil)
    }

    @objc private func stopRouting() {
        NotificationCenter.default.post(name: .stopRouting, object: nil)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let startRouting = Notification.Name("com.audiosync.startRouting")
    static let stopRouting = Notification.Name("com.audiosync.stopRouting")
    static let audioDevicesChanged = Notification.Name("com.audiosync.audioDevicesChanged")
}
