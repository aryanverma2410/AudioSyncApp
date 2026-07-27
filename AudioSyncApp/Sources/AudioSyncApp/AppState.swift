import Foundation
import SwiftUI
import CoreAudio
import AudioToolbox
import Combine

// MARK: - App State

/// Central coordinator: device discovery, system audio capture, multi-output routing.
@MainActor
class AppState: ObservableObject {
    let deviceDiscovery = DeviceDiscovery()

    let systemCapturer = SystemAudioCapturer()
    let outputEngine = MultiOutputEngine()

    @Published var isActive = false
    @Published var deviceSettings: [String: DeviceSettings] = [:]  // keyed by device UID
    @Published var errorMessage: String?
    @Published var vuLevels: [String: Float] = [:]  // Per-device VU level (refreshed by timer)
    @Published var deviceOrder: [String] = []  // Device UIDs in display order
    @Published var profiles: [String: RoomProfile] = [:]
    @Published var activeProfileName: String?
    @Published var masterVolume: Float = 1.0
    @Published var isAutoSyncing = false
    @Published var habits: [String: DeviceHabit] = [:]  // Learned per-device habits
    private var cancellables = Set<AnyCancellable>()

    /// Human-readable description of the active capture method (for UI display).
    var captureMethodDescription: String {
        systemCapturer.captureMethod.rawValue
    }

    // MARK: - Persistence Keys
    
    private static let kSettingsKey = "com.audiosync.deviceSettings"
    private static let kOrderKey = "com.audiosync.deviceOrder"
    private static let kProfilesKey = "com.audiosync.profiles"
    private static let kActiveProfileKey = "com.audiosync.activeProfile"
    private static let kMasterVolumeKey = "com.audiosync.masterVolume"
    private static let kHabitsKey = "com.audiosync.habits"

    // MARK: - Init

    init() {
        // Restore persisted settings
        restoreSettings()
        
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

        // Audio device hotplug: when DeviceDiscovery detects changes, sync new devices
        deviceDiscovery.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.syncNewDevices()
                }
            }
            .store(in: &cancellables)

        // Auto-save settings whenever they change
        $deviceSettings
            .dropFirst() // skip initial restored value
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveSettings() }
        // FIXME: Add system audio capture status
            .store(in: &cancellables)

        $deviceOrder
            .dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveSettings() }
            .store(in: &cancellables)

        $habits
            .dropFirst()
            .debounce(for: .seconds(2.0), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveSettings() }
            .store(in: &cancellables)
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

        // Initialize device order from discovered devices
        if deviceOrder.isEmpty {
            deviceOrder = deviceDiscovery.devices.map { $0.uid }
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
        recordHabit(uid: uid)
 // Learn user's delay preference
    }

    func updateVolume(_ uid: String, volume: Float) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.volume = volume
        outputEngine.updateVolume(for: uid, volume: volume)
        recordHabit(uid: uid)  // Learn user's volume preference
    }

    func updateMute(_ uid: String, isMuted: Bool) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.isMuted = isMuted
        outputEngine.updateMute(for: uid, isMuted: isMuted)
    }

    func updateEQ(_ uid: String, bass: Float, treble: Float, mid: Float) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.bass = bass
        deviceSettings[uid]?.treble = treble
        deviceSettings[uid]?.mid = mid
        outputEngine.updateEQ(for: uid, bass: bass, treble: treble, mid: mid)
    }

    func updateRole(_ uid: String, role: SpeakerRole) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.role = role
        outputEngine.updateRole(for: uid, role: role)
    }

    /// Normalize all enabled speakers to the same volume (uses the average of current volumes)
    func normalizeVolumes() {
        let enabledSettings = deviceSettings.filter { $0.value.isEnabled && !$0.value.isMuted }
        guard enabledSettings.count > 1 else { return }
        let avgVolume = enabledSettings.values.map { $0.volume }.reduce(0, +) / Float(enabledSettings.count)
        for (uid, _) in enabledSettings {
            deviceSettings[uid]?.volume = avgVolume
            outputEngine.updateVolume(for: uid, volume: avgVolume)
        }
    }

    /// Set all enabled, non-muted devices to a specific volume level.
    func setAllVolumeToLevel(_ targetVolume: Float) {
        for (uid, settings) in deviceSettings where settings.isEnabled && !settings.isMuted {
            deviceSettings[uid]?.volume = targetVolume
            outputEngine.updateVolume(for: uid, volume: targetVolume)
        }
    }

    /// Set master volume (proportionally scales all speakers).
    func setMasterVolume(_ level: Float) {
        masterVolume = level
        outputEngine.setMasterVolume(level)
    }

    /// Reset all speakers' EQ to flat.
    func resetAllEQ() {
        outputEngine.resetAllEQ()
        for uid in deviceSettings.keys {
            deviceSettings[uid]?.bass = 0
            deviceSettings[uid]?.treble = 0
            deviceSettings[uid]?.mid = 0
        }
    }

    // MARK: - Habit Learning

    /// Record a user adjustment into the per-device habit tracker (EMA).
    /// Called from updateDelay and updateVolume.
    private func recordHabit(uid: String) {
        guard let settings = deviceSettings[uid] else { return }
        if habits[uid] == nil {
            habits[uid] = DeviceHabit()
        }
        habits[uid]?.observe(volume: settings.volume, delay: settings.delayMs)
    }

    /// Apply learned habits to all devices where we have confident data.
    /// Used as a complement to auto-sync: if the user consistently prefers a
    /// certain delay/volume, restore it (especially on reconnect).
    /// Returns UIDs that were updated.
    @discardableResult
    func applyLearnedHabits() -> [String] {
        var updated: [String] = []
        for (uid, habit) in habits where habit.isConfident {
            guard let settings = deviceSettings[uid], settings.isEnabled else { continue }
            let learnedVol = habit.volumeEMA
            let learnedDelay = habit.delayEMA
            // Only apply if significantly different from current
            if abs(settings.volume - learnedVol) > 0.05 {
                deviceSettings[uid]?.volume = learnedVol
                outputEngine.updateVolume(for: uid, volume: learnedVol)
            }
            if abs(settings.delayMs - learnedDelay) > 5 {
                deviceSettings[uid]?.delayMs = learnedDelay
                outputEngine.updateDelay(for: uid, ms: learnedDelay)
            }
            updated.append(uid)
        }
        if !updated.isEmpty { saveSettings() }
        return updated
    }

    /// Get the learned habit summary for a device (for UI display).
    func habitSummary(for uid: String) -> String? {
        guard let habit = habits[uid], habit.isConfident else { return nil }
        return String(format: "Usually: %.0f%% vol, %.0fms delay (%d obs)",
                      habit.volumeEMA * 100, habit.delayEMA, habit.observationCount)
    }

    // MARK: - Room Profiles

    /// Save the current configuration as a named profile.
    func saveProfile(name: String) {
        let profile = RoomProfile(
            name: name,
            deviceSettings: deviceSettings,
            deviceOrder: deviceOrder,
            metronomeBPM: outputEngine.metronomeBPM,
            timestamp: Date()
        )
        profiles[name] = profile
        activeProfileName = name
        saveSettings()
    }

    /// Load a saved profile and apply its settings.
    func loadProfile(name: String) {
        guard let profile = profiles[name] else { return }
        deviceSettings = profile.deviceSettings
        deviceOrder = profile.deviceOrder
        outputEngine.setMetronomeBPM(profile.metronomeBPM)
        activeProfileName = name
        // Re-apply settings to the engine if active
        if isActive {
            for (uid, settings) in deviceSettings where settings.isEnabled {
                outputEngine.updateVolume(for: uid, volume: settings.volume)
                outputEngine.updateDelay(for: uid, ms: settings.delayMs)
                outputEngine.updateEQ(for: uid, bass: settings.bass, treble: settings.treble, mid: settings.mid)
                outputEngine.updateRole(for: uid, role: settings.role)
            }
        }
    }

    /// Delete a saved profile.
    func deleteProfile(name: String) {
        profiles.removeValue(forKey: name)
        if activeProfileName == name { activeProfileName = nil }
        saveSettings()
    }

    /// Rename a saved profile.
    func renameProfile(old: String, new: String) {
        guard var profile = profiles[old] else { return }
        profiles.removeValue(forKey: old)
        profile.name = new
        profiles[new] = profile
        if activeProfileName == old { activeProfileName = new }
        saveSettings()
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

    func moveDevice(from source: IndexSet, to destination: Int) {
        deviceOrder.move(fromOffsets: source, toOffset: destination)
    }

    /// Restart routing to pick up any devices that weren't properly added.
    func restartRouting() async {
        guard isActive else { return }
        DLog("[AppState] Restarting routing for device sync...")
        stop()
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s settle
        await start()
    }

    // MARK: - Auto-Delay Compensation

    @MainActor
    func autoDelayCompensate() -> [String: Float] {
        guard isActive else { return [:] }
        isAutoSyncing = true

        // Only include enabled, non-virtual devices in auto-delay measurement
        let enabledUIDs = Set(
            deviceSettings.filter { _, s in s.isEnabled }
                .map { uid, _ in uid }
        )
        let currentDelays: [String: Float] = deviceSettings.compactMapValues { $0.isEnabled ? $0.delayMs : nil }
        let compensated = outputEngine.applyAutoDelayCompensation(enabledUIDs: enabledUIDs, currentDelays: currentDelays)

        // Cross-check with learned habits: if user consistently sets a device
        // to a delay that differs from auto-sync's suggestion, prefer the habit.
        // This prevents auto-sync from overriding intentional tuning.
        var finalDelays = compensated
        for (uid, autoDelay) in compensated {
            if let habit = habits[uid], habit.isConfident {
                let learnedDelay = habit.delayEMA
                let drift = abs(autoDelay - learnedDelay)
                // If auto-sync suggests 0 but user habitually uses >50ms, trust the habit
                if autoDelay == 0 && learnedDelay > 50 {
                    finalDelays[uid] = round(learnedDelay / 5.0) * 5.0
                    DLog("[AutoSync] Habit override for '\(uid)': auto=\(autoDelay)ms → learned=\(learnedDelay)ms")
                }
                // If auto-sync and habit disagree by >100ms, split the difference
                else if drift > 100 {
                    let blended = (autoDelay + learnedDelay) / 2
                    finalDelays[uid] = round(blended / 5.0) * 5.0
                    DLog("[AutoSync] Blended for '\(uid)': auto=\(autoDelay)ms + learned=\(learnedDelay)ms → \(blended)ms")
                }
            }
        }

        for (uid, delayMs) in finalDelays {
            deviceSettings[uid]?.delayMs = delayMs
        }
        isAutoSyncing = false
        return finalDelays
    }

    // MARK: - VU Meters

    /// Get the current peak level for a device (0.0...1.0).
    func peakLevel(for uid: String) -> Float {
        // FIXME: Add latency measurement logging
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

    // MARK: - Persistence

    private func saveSettings() {
        let defaults = UserDefaults.standard
        if let encoded = try? JSONEncoder().encode(deviceSettings) {
            defaults.set(encoded, forKey: Self.kSettingsKey)
        }
        defaults.set(deviceOrder, forKey: Self.kOrderKey)
        // Persist profiles
        if let encoded = try? JSONEncoder().encode(profiles) {
            defaults.set(encoded, forKey: Self.kProfilesKey)
        }
        defaults.set(activeProfileName, forKey: Self.kActiveProfileKey)
        defaults.set(masterVolume, forKey: Self.kMasterVolumeKey)
        // Persist habits (learned device preferences)
        if let encoded = try? JSONEncoder().encode(habits) {
            defaults.set(encoded, forKey: Self.kHabitsKey)
        }
        DLog("[AppState] Settings saved (\(deviceSettings.count) devices, \(profiles.count) profiles, \(habits.count) habits)")
    }

    private func restoreSettings() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.kSettingsKey),
           let saved = try? JSONDecoder().decode([String: DeviceSettings].self, from: data) {
            deviceSettings = saved
            DLog("[AppState] Restored \(saved.count) device settings")
        }
        deviceOrder = defaults.stringArray(forKey: Self.kOrderKey) ?? []
        // Restore profiles
        if let data = defaults.data(forKey: Self.kProfilesKey),
           let saved = try? JSONDecoder().decode([String: RoomProfile].self, from: data) {
            profiles = saved
            DLog("[AppState] Restored \(saved.count) room profiles")
        }
        activeProfileName = defaults.string(forKey: Self.kActiveProfileKey)
        masterVolume = defaults.float(forKey: Self.kMasterVolumeKey)
        if masterVolume <= 0 { masterVolume = 1.0 }
        // Apply master volume to engine
        outputEngine.setMasterVolume(masterVolume)
        // Restore habits (learned device preferences)
        if let data = defaults.data(forKey: Self.kHabitsKey),
           let saved = try? JSONDecoder().decode([String: DeviceHabit].self, from: data) {
            habits = saved
            DLog("[AppState] Restored \(saved.count) device habits")
        }
        // Auto-load active profile on launch
        if let name = activeProfileName, profiles[name] != nil {
            loadProfile(name: name)
        }
    }

}
