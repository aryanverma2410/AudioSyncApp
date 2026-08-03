import Cocoa
import SwiftUI
import ServiceManagement
import Carbon
import CoreWLAN

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up menu bar item
        setupMenuBarItem()

        setupGlobalHotkeys()

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

    // MARK: - Global Hotkeys

    private var hotkeyRefs: [EventHotKeyRef] = []

    private func setupGlobalHotkeys() {
        registerHotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), id: 1)  // ⌘⇧K — toggle karaoke
        registerHotkey(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | shiftKey), id: 2)  // ⌘⇧M — toggle mute all
        registerHotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey), id: 3)  // ⌘⇧S — start/stop
        registerHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), id: 4)  // ⌘⇧Space — sleep timer
        DLog("[AppDelegate] Global hotkeys registered")
    }

    private func registerHotkey(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        // Get event dispatcher
        let eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // Install event handler
        let handler: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef = eventRef else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                             nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            // Post notification based on hotkey ID
            let name: Notification.Name
            switch hkID.id {
            case 1: name = Notification.Name("com.audiosync.toggleKaraoke")
            case 2: name = Notification.Name("com.audiosync.toggleMuteAll")
            case 3: name = Notification.Name("com.audiosync.toggleRouting")
            case 4: name = Notification.Name("com.audiosync.toggleSleepTimer")
            default: return noErr
            }
            NotificationCenter.default.post(name: name, object: nil)
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, [eventSpec], nil, nil)

        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: OSType(0x415553_4C), id: id)  // 'AUSL'
        RegisterEventHotKey(keyCode, modifiers, hotkeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref = ref { hotkeyRefs.append(ref) }
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
