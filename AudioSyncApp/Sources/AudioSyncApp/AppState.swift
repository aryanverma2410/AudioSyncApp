import Foundation
import SwiftUI
import CoreAudio
import AudioToolbox

// MARK: - App State

/// Central coordinator that ties together device discovery, system audio capture,
/// multi-output routing, and profile management.
@MainActor
class AppState: ObservableObject {
    let deviceDiscovery = DeviceDiscovery()
    let systemCapturer = SystemAudioCapturer()
    let outputEngine = MultiOutputEngine()

    @Published var isActive = false
    @Published var deviceSettings: [String: DeviceSettings] = [:]  // keyed by device UID
    @Published var errorMessage: String?
    @Published var vuLevels: [String: Float] = [:]  // Per-device VU level (refreshed by timer)

    // Stored so AudioObjectAddPropertyListener callback pointer remains valid
    private var deviceChangeAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Human-readable description of the active capture method (for UI display).
    var captureMethodDescription: String {
        systemCapturer.captureMethod.rawValue
    }

    // MARK: - Init

    init() {
        // Wire up the capturer to write DIRECTLY to ring buffers.
        // distributeAudioDirect is nonisolated (thread-safe), so calling from
        // the capturer's background queue is fine. This bypasses AVAudioEngine
        // entirely — SCStream → distributeAudioDirect → ringBuffer → HAL callback.
        systemCapturer.onAudioBuffer = { [weak self] buffer in
            self?.outputEngine.distributeAudioDirect(buffer)
        }

        // Observe menu bar routing notifications from AppDelegate
        NotificationCenter.default.addObserver(forName: .startRouting, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.start() }
        }
        NotificationCenter.default.addObserver(forName: .stopRouting, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }

        // Sleep/wake recovery: restart routing after wake
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                DLog("[AppState] System woke from sleep — restarting routing")
                self.stop()
                // Brief delay for audio subsystem to settle after wake
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.start()
            }
        }

        // Audio device hotplug: refresh device list when devices appear/disappear
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &deviceChangeAddr, { _, _, _, _ -> Int32 in
            DLog("[AppState] Audio device list changed — scheduling sync")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .audioDevicesChanged, object: nil)
            }
            return noErr
        }, nil)

        // Auto-add new devices to active routing session
        NotificationCenter.default.addObserver(forName: .audioDevicesChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncNewDevices()
            }
        }
    }

    // MARK: - Start / Stop

    func start() async {
        guard !isActive else { return }
        errorMessage = nil

        // Step 1: Discover devices
        deviceDiscovery.refreshDevices()

        guard !deviceDiscovery.devices.isEmpty else {
            errorMessage = "No audio output devices found. Connect a speaker or headphones."
            return
        }

        // Step 2: Start system audio capture FIRST (we need to know the capture device to exclude it from outputs)
        DLog("Starting system audio capture...")
        do {
            try await systemCapturer.startCapture()
        } catch {
            let errorDesc = error.localizedDescription
            if errorDesc.contains("declined") || errorDesc.contains("denied") || errorDesc.contains("TCC") {
                errorMessage = """
                Screen Recording permission denied. To fix:
                
                1. Open System Settings → Privacy & Security → Screen Recording
                2. Click '+' and add AudioSyncApp
                3. Or find 'AudioSyncApp' in the list and enable it
                4. Restart AudioSyncApp after granting
                
                The app needs Screen Recording permission to capture system audio.
                """
            } else {
                errorMessage = "Failed to start audio capture: \(errorDesc)"
            }
            DLog("ERROR: capture failed — \(error)")
            return
        }

        // Step 3: Build device list with settings, EXCLUDING the capture device to prevent feedback
        let captureDeviceID = systemCapturer.activeCaptureDeviceID
        let devicesWithSettings = deviceDiscovery.devices.compactMap { device -> (AudioOutputDevice, DeviceSettings)? in
            // Exclude the capture device from outputs (would create feedback loop)
            if let capID = captureDeviceID, device.id == capID {
                DLog("Excluding '\(device.name)' from outputs (capture source)")
                return nil
            }
            let settings = deviceSettings[device.uid] ?? defaultSettings(for: device)
            if deviceSettings[device.uid] == nil {
                deviceSettings[device.uid] = settings
            }
            return (device: device, settings: settings)
        }

        // Log what we're about to configure
        DLog("Starting routing with \(devicesWithSettings.count) device(s) (excluded capture device):")
        for (device, settings) in devicesWithSettings {
            DLog("  - \(device.name) (\(device.transportType.rawValue), id=\(device.id), uid=\(device.uid.prefix(20))…, sr=\(device.sampleRate)), enabled=\(settings.isEnabled), delay=\(settings.delayMs)ms")
        }

        guard !devicesWithSettings.isEmpty else {
            errorMessage = "No output devices available after excluding capture device."
            systemCapturer.stopCapture()
            return
        }

        // Step 4: Configure the output engine
        do {
            try outputEngine.configure(devices: devicesWithSettings)
        } catch {
            errorMessage = "Failed to configure audio engine: \(error.localizedDescription)"
            DLog("ERROR: configure failed — \(error)")
            systemCapturer.stopCapture()
            return
        }

        // Step 5: Start the output engine (wrapped in crash guard)
        DLog("Starting output engine...")
        do {
            try outputEngine.startSafely()
        } catch {
            errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
            outputEngine.stop()
            systemCapturer.stopCapture()
            DLog("ERROR: start failed — \(error)")
            return
        }

        isActive = true
        startVUTimer()
        DLog("Routing started successfully!")
    }

    func stop() {
        guard isActive else { return }

        vuTimer?.invalidate(); vuTimer = nil

        systemCapturer.stopCapture()
        outputEngine.stop()
        isActive = false
        DLog("Routing stopped.")
    }

    // MARK: - Device Controls

    func toggleDevice(_ uid: String, enabled: Bool) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.isEnabled = enabled

        if enabled {
            // Find the device and add it
            if let device = deviceDiscovery.devices.first(where: { $0.uid == uid }) {
                let settings = deviceSettings[uid] ?? defaultSettings(for: device)
                try? outputEngine.addDevice(device, settings: settings)
            }
        } else {
            outputEngine.removeDevice(uid)
        }
    }

    /// Sync newly appeared devices into the active routing session.
    /// Called when CoreAudio detects a device list change while routing is active.
    private func syncNewDevices() {
        guard isActive else { return }
        let captureDeviceID = systemCapturer.activeCaptureDeviceID
        
        for device in deviceDiscovery.devices {
            // Skip capture device (feedback prevention)
            if let capID = captureDeviceID, device.id == capID { continue }
            
            // Already in engine? Skip
            if deviceSettings[device.uid] != nil { continue }
            
            // New device — add with default settings
            let settings = defaultSettings(for: device)
            deviceSettings[device.uid] = settings
            DLog("[AppState] Auto-adding new device '\(device.name)' to routing")
            
            if settings.isEnabled {
                try? outputEngine.addDevice(device, settings: settings)
            }
        }
    }

    func updateDelay(_ uid: String, ms: Float) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.delayMs = ms
        outputEngine.updateDelay(for: uid, ms: ms)
    }

    func updateVolume(_ uid: String, volume: Float) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.volume = volume
        outputEngine.updateVolume(for: uid, volume: volume)
    }

    func updateMute(_ uid: String, isMuted: Bool) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.isMuted = isMuted
        outputEngine.updateMute(for: uid, isMuted: isMuted)
    }

    /// Play a 440Hz test tone directly into a specific device's ring buffer.
    /// This bypasses the capture pipeline to test the HAL output unit independently.
    func testTone(for uid: String) {
        outputEngine.injectTestTone(for: uid)
    }

    /// Play a 440Hz test tone to ALL device ring buffers.
    func testToneAll() {
        outputEngine.injectTestToneAll()
    }

    // MARK: - Auto-Delay Compensation

    /// Measure latencies and apply auto-delay compensation.
    /// Most-delayed speaker = 0ms, others offset. Returns applied delays.
    @MainActor
    func autoDelayCompensate() -> [String: Float] {
        let compensated = outputEngine.applyAutoDelayCompensation()
        // Update deviceSettings to reflect the new delays
        for (uid, delayMs) in compensated {
            deviceSettings[uid]?.delayMs = delayMs
        }
        return compensated
    }

    // MARK: - VU Meters

    /// Get the current peak level for a device (0.0...1.0).
    func peakLevel(for uid: String) -> Float {
        outputEngine.peakLevel(for: uid)
    }

    // MARK: - VU Meter Timer

    private var vuTimer: Timer?

    private func startVUTimer() {
        vuTimer?.invalidate()
        vuTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var levels: [String: Float] = [:]
                for device in self.deviceDiscovery.devices {
                    levels[device.uid] = self.outputEngine.peakLevel(for: device.uid)
                }
                self.vuLevels = levels
            }
        }
    }

    // MARK: - Default Settings

    private func defaultSettings(for device: AudioOutputDevice) -> DeviceSettings {
        if device.transportType.isBluetooth {
            return .defaultBluetooth
        }
        return DeviceSettings()
    }

    /// Ensures a DeviceSettings entry exists in deviceSettings for the given device UID.
    /// This is critical because UI bindings use optional chaining on deviceSettings[uid],
    /// which silently fails if the key is nil (e.g., before Start Routing is clicked).
    private func ensureSettingsExist(for uid: String) {
        if deviceSettings[uid] != nil { return }
        if let device = deviceDiscovery.devices.first(where: { $0.uid == uid }) {
            deviceSettings[uid] = defaultSettings(for: device)
        } else {
            deviceSettings[uid] = DeviceSettings()
        }
    }

}
