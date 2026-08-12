import Foundation
import CoreAudio
import AudioToolbox
import AppKit

// MARK: - Setup Assistant
// Automates the complete first-time setup:
// 1. Installs BlackHole 2ch (if missing)
// 2. Creates a Multi-Output Aggregate Device (if missing)
// 3. Sets it as the default output device
//
// This replaces the manual "Audio MIDI Setup" dance that users
// had to do before. One click → everything configured.

@MainActor
class SetupAssistant: ObservableObject {
    @Published var state: SetupState = .notStarted
    @Published var statusMessage: String = ""
    @Published var progress: Double = 0

    enum SetupState: Equatable {
        case notStarted
        case checking
        case installingBlackHole
        case creatingAggregate
        case settingDefault
        case done
        case failed(String)
    }

    // MARK: - Public

    /// Run the full setup pipeline. Skips steps that are already done.
    func runSetup() async {
        state = .checking
        progress = 0.0
        statusMessage = "Checking current setup…"

        // Step 1: Check if BlackHole is installed
        let hasBlackHole = findBlackHoleDevice() != nil
        progress = 0.1

        if !hasBlackHole {
            statusMessage = "Installing BlackHole audio driver…"
            state = .installingBlackHole
            let installed = await installBlackHole()
            guard installed else {
                state = .failed("Failed to install BlackHole. Try manually: brew install blackhole-2ch")
                return
            }
            // Wait for CoreAudio to register the new device
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        progress = 0.4

        // Step 2: Check/create Multi-Output Aggregate Device
        let existingAggregate = findAggregateDevice()
        let aggregateDeviceID: AudioObjectID

        if let existing = existingAggregate {
            aggregateDeviceID = existing
            statusMessage = "Multi-Output device already exists ✓"
        } else {
            statusMessage = "Creating Multi-Output device…"
            state = .creatingAggregate
            guard let created = createAggregateDevice() else {
                state = .failed("Failed to create Multi-Output device. Try Audio MIDI Setup manually.")
                return
            }
            aggregateDeviceID = created
            // Wait for the aggregate to register
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        progress = 0.7

        // Step 3: Set as default output
        statusMessage = "Setting Multi-Output as default audio device…"
        state = .settingDefault
        setDefaultOutputDevice(aggregateDeviceID)
        progress = 0.9

        // Done
        try? await Task.sleep(nanoseconds: 500_000_000)
        statusMessage = "Setup complete! Click Start to begin routing audio."
        state = .done
        progress = 1.0
    }

    // MARK: - BlackHole Detection

    /// Find the BlackHole 2ch device ID, if installed.
    func findBlackHoleDevice() -> AudioObjectID? {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }

        for id in ids {
            let name = id.caDisplayName
            if name.localizedCaseInsensitiveContains("BlackHole") && id.caHasOutputStreams {
                DLog("[SetupAssistant] Found BlackHole: '\(name)' (id=\(id))")
                return id
            }
        }
        return nil
    }

    // MARK: - BlackHole Installation

    /// Install BlackHole 2ch via Homebrew (preferred) or direct pkg download.
    private func installBlackHole() async -> Bool {
        // Try Homebrew first
        if await installViaHomebrew() {
            return true
        }

        // Fallback: download and install the pkg directly
        return await installViaDirectDownload()
    }

    private func installViaHomebrew() async -> Bool {
        statusMessage = "Installing BlackHole via Homebrew…"
        DLog("[SetupAssistant] Attempting Homebrew install")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        process.arguments = ["install", "blackhole-2ch"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                DLog("[SetupAssistant] Homebrew install succeeded")
                return true
            }
        } catch {
            DLog("[SetupAssistant] Homebrew not available: \(error)")
        }
        return false
    }

    private func installViaDirectDownload() async -> Bool {
        statusMessage = "Downloading BlackHole installer…"
        DLog("[SetupAssistant] Attempting direct download install")

        // BlackHole 2ch pkg URL from existential.audio
        let urlString = "https://existential.audio/downloads/BlackHole2ch.v0.5.1.pkg"
        guard let url = URL(string: urlString) else { return false }

        let tempDir = NSTemporaryDirectory()
        let pkgPath = tempDir + "BlackHole2ch.pkg"

        do {
            // Download
            let (pkgURL, _) = try await URLSession.shared.download(from: url)
            try FileManager.default.moveItem(at: pkgURL, to: URL(fileURLWithPath: pkgPath))
            DLog("[SetupAssistant] Downloaded to \(pkgPath)")

            statusMessage = "Installing BlackHole (requires admin password)…"

            // Install via installer command (prompts for admin password)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
            process.arguments = ["-pkg", pkgPath, "-target", "/"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            // Cleanup
            try? FileManager.default.removeItem(atPath: pkgPath)

            if process.terminationStatus == 0 {
                DLog("[SetupAssistant] Direct install succeeded")
                return true
            } else {
                DLog("[SetupAssistant] Direct install failed with status \(process.terminationStatus)")
                return false
            }
        } catch {
            DLog("[SetupAssistant] Download/install error: \(error)")
            try? FileManager.default.removeItem(atPath: pkgPath)
            return false
        }
    }

    // MARK: - Aggregate Device Creation

    /// Find existing Multi-Output aggregate device that we created.
    func findAggregateDevice() -> AudioObjectID? {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }

        for id in ids {
            let name = id.caDisplayName
            // Look for our named aggregate or user-created multi-output
            if name.localizedCaseInsensitiveContains("AudioSync") &&
               name.localizedCaseInsensitiveContains("Multi-Output") {
                DLog("[SetupAssistant] Found existing aggregate: '\(name)' (id=\(id))")
                return id
            }
        }
        return nil
    }

    /// Create a Multi-Output Aggregate Device containing all output devices + BlackHole.
    /// Uses the CoreAudio AudioAggregateDevice API (programmatic equivalent of Audio MIDI Setup).
    func createAggregateDevice() -> AudioObjectID? {
        DLog("[SetupAssistant] Creating Multi-Output Aggregate Device")

        // Gather all output device UIDs
        var deviceUIDs: [String] = []

        // Get all current output devices
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }

        var bhUID: String?
        var otherUIDs: [String] = []

        for id in ids {
            guard id.caHasOutputStreams else { continue }
            let name = id.caDisplayName
            let uid = deviceUID(id)

            if name.localizedCaseInsensitiveContains("BlackHole") {
                bhUID = uid
            } else {
                otherUIDs.append(uid)
            }
        }

        // Add real speakers first, then BlackHole last
        deviceUIDs = otherUIDs
        if let bh = bhUID {
            deviceUIDs.append(bh)
        }

        guard !deviceUIDs.isEmpty else {
            DLog("[SetupAssistant] No output devices found for aggregate")
            return nil
        }

        let aggregateName = "AudioSync Multi-Output"

        let desc: [String: Any] = [
            "name": aggregateName,
            "uid": "com.audiosync.aggregate.\(UUID().uuidString)",
            "subdevices": deviceUIDs,
            "master-device": deviceUIDs.first ?? "",
            "is-private": false
        ]

        var deviceID: AudioObjectID = 0
        let cfDesc = desc as CFDictionary
        let status = AudioHardwareCreateAggregateDevice(cfDesc, &deviceID)

        if status != noErr {
            DLog("[SetupAssistant] AudioHardwareCreateAggregateDevice failed: \(status). User may need to create Multi-Output manually in Audio MIDI Setup.")
            return nil
        }

        DLog("[SetupAssistant] Created aggregate device id=\(deviceID)")
        return deviceID
    }

    // MARK: - Set Default Output

    /// Set a device as the system default output.
    func setDefaultOutputDevice(_ deviceID: AudioObjectID) {
        var id = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &id)

        if status == noErr {
            DLog("[SetupAssistant] Set default output device to id=\(deviceID)")
        } else {
            DLog("[SetupAssistant] Failed to set default output: \(status)")
        }
    }

    /// Check if BlackHole is installed and a multi-output aggregate exists.
    var isFullySetup: Bool {
        findBlackHoleDevice() != nil && findAggregateDevice() != nil
    }

    // MARK: - Helpers

    private func deviceUID(_ id: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfString: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfString else { return UUID().uuidString }
        return cfString as String
    }
}
