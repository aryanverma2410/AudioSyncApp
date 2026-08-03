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
    @Published var isProfileModified = false
    @Published var masterVolume: Float = 1.0
    @Published var audioMode: AudioMode = .normal
    @Published var isAutoSyncing = false

    // Sleep timer
    @Published var sleepTimerMinutes: Int? = nil
    @Published var sleepTimerRemaining: Int = 0

    // DSP toggles
    @Published var isMonoMode: Bool = false
    @Published var isCompressorEnabled: Bool = false
    @Published var reverbPreset: ReverbPreset = .none

    // Network profile mapping
    @Published var networkProfileMap: [String: String] = [:]  // SSID → profile name
    @Published var currentSSID: String = ""
    let calibrator = AcousticCalibrator()
    let setupAssistant = SetupAssistant()
    private var cancellables = Set<AnyCancellable>()

    /// Human-readable description of the active capture method (for UI display).
    var captureMethodDescription: String {
        systemCapturer.captureMethod.rawValue
    }

    /// Ordered devices for health dashboard display.
    var orderedDevicesForHealth: [AudioOutputDevice] {
        let devices = deviceDiscovery.devices
        let order = deviceOrder
        if order.isEmpty { return devices }
        var result: [AudioOutputDevice] = []
        for uid in order {
            if let device = devices.first(where: { $0.uid == uid }) {
                result.append(device)
            }
        }
        for device in devices where !order.contains(device.uid) {
            result.append(device)
        }
        return result
    }

    // MARK: - Persistence Keys
    
    private static let kSettingsKey = "com.audiosync.deviceSettings"
    private static let kOrderKey = "com.audiosync.deviceOrder"
    private static let kProfilesKey = "com.audiosync.profiles"
    private static let kActiveProfileKey = "com.audiosync.activeProfile"
    private static let kMasterVolumeKey = "com.audiosync.masterVolume"

    /// Snapshot of the profile when it was loaded, used to detect modifications.
    private var loadedProfileSnapshot: RoomProfile?

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

        // Wire calibrator to engine (for injecting calibration chirps)
        calibrator.outputEngine = outputEngine

        // Observe menu bar routing notifications from AppDelegate
        NotificationCenter.default.addObserver(forName: .startRouting, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.start() }
        }
        NotificationCenter.default.addObserver(forName: .stopRouting, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
        }

        // Global hotkey actions
        NotificationCenter.default.addObserver(forName: Notification.Name("com.audiosync.toggleKaraoke"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newMode: AudioMode = self.audioMode == .karaoke ? .normal : .karaoke
                self.setAudioMode(newMode)
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("com.audiosync.toggleMuteAll"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allMuted = self.deviceSettings.values.allSatisfy { $0.isMuted }
                for (uid, _) in self.deviceSettings {
                    self.updateMute(uid, isMuted: !allMuted)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("com.audiosync.toggleRouting"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isActive { self.stop() } else { Task { await self.start() } }
            }
        }
        NotificationCenter.default.addObserver(forName: Notification.Name("com.audiosync.toggleSleepTimer"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.sleepTimerMinutes != nil {
                    self.setSleepTimer(minutes: nil)
                } else {
                    self.setSleepTimer(minutes: 30)
                }
            }
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
        checkProfileModified()

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
            if device.transportType.isBluetooth {
                DLog("[AppState] BT auto-reconnect: '\(device.name)' detected, resuming routing")
            }
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
        checkProfileModified()
    }

    func updateVolume(_ uid: String, volume: Float) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.volume = volume
        outputEngine.updateVolume(for: uid, volume: volume)
        checkProfileModified()
    }

    func updateMute(_ uid: String, isMuted: Bool) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.isMuted = isMuted
        outputEngine.updateMute(for: uid, isMuted: isMuted)
        checkProfileModified()
    }

    /// Set all enabled, non-muted devices to a specific volume level.
    func setAllVolumeToLevel(_ targetVolume: Float) {
        for (uid, settings) in deviceSettings where settings.isEnabled && !settings.isMuted {
            deviceSettings[uid]?.volume = targetVolume
            outputEngine.updateVolume(for: uid, volume: targetVolume)
        }
        checkProfileModified()
    }

    /// Set master volume (proportionally scales all speakers).
    func setMasterVolume(_ level: Float) {
        masterVolume = level
        outputEngine.setMasterVolume(level)
    }

    func setAudioMode(_ mode: AudioMode) {
        audioMode = mode
        outputEngine.setAudioMode(mode)
    }

    // MARK: - Sleep Timer

    private var sleepTimer: Timer?

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        if let mins = minutes {
            sleepTimerMinutes = mins
            sleepTimerRemaining = mins * 60
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                Task { @MainActor [weak self] in
                    guard let self else { t.invalidate(); return }
                    self.sleepTimerRemaining -= 1
                    if self.sleepTimerRemaining <= 0 {
                        self.stop()
                        self.sleepTimerMinutes = nil
                        self.sleepTimerRemaining = 0
                        t.invalidate()
                        DLog("[AppState] Sleep timer expired — routing stopped")
                    }
                }
            }
        } else {
            sleepTimerMinutes = nil
            sleepTimerRemaining = 0
        }
    }

    // MARK: - DSP Controls

    func setMonoMode(_ enabled: Bool) {
        isMonoMode = enabled
        outputEngine.setMonoMode(enabled)
    }

    func setCompressor(_ enabled: Bool) {
        isCompressorEnabled = enabled
        outputEngine.setCompressor(enabled: enabled)
    }

    func setReverb(_ preset: ReverbPreset) {
        reverbPreset = preset
        // Map to engine's Reverb.Preset
        if let enginePreset = Reverb.Preset(rawValue: preset.rawValue) {
            outputEngine.setReverb(enginePreset)
        }
    }

    // MARK: - Subwoofer

    func setSubwoofer(_ uid: String, enabled: Bool, crossoverHz: Float = 80) {
        ensureSettingsExist(for: uid)
        deviceSettings[uid]?.isSubwoofer = enabled
        deviceSettings[uid]?.crossoverHz = crossoverHz
        outputEngine.setSubwoofer(uid, enabled: enabled, crossoverHz: crossoverHz)
        checkProfileModified()
    }

    // MARK: - Network Profile Auto-Switch

    private var wifiMonitorTimer: Timer?

    func startNetworkMonitoring() {
        wifiMonitorTimer?.invalidate()
        checkCurrentNetwork()
        wifiMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkCurrentNetwork() }
        }
    }

    private func checkCurrentNetwork() {
        // Get current SSID via CoreWLAN
        // Using process substitution to avoid import complexity
        let task = Process()
        task.launchPath = "/usr/sbin/airport"
        task.arguments = ["-I"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SSID: ") {
                let ssid = String(trimmed.dropFirst("SSID: ".count))
                if ssid != currentSSID {
                    currentSSID = ssid
                    DLog("[AppState] WiFi changed to '\(ssid)'")
                    if let profileName = networkProfileMap[ssid] {
                        DLog("[AppState] Auto-switching to profile '\(profileName)' for SSID '\(ssid)'")
                        loadProfile(name: profileName)
                    }
                }
                return
            }
        }
    }

    // MARK: - Profile Modification Detection

    /// Marks the active profile as modified if current settings differ from the loaded snapshot.
    private func checkProfileModified() {
        guard let snapshot = loadedProfileSnapshot else { return }
        if deviceSettings != snapshot.deviceSettings
            || deviceOrder != snapshot.deviceOrder
            || outputEngine.metronomeBPM != snapshot.metronomeBPM {
            isProfileModified = true
        }
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
        isProfileModified = false
        loadedProfileSnapshot = profile
        saveSettings()
    }

    /// Load a saved profile and apply its settings.
    func loadProfile(name: String) {
        guard let profile = profiles[name] else { return }
        deviceSettings = profile.deviceSettings
        deviceOrder = profile.deviceOrder
        outputEngine.setMetronomeBPM(profile.metronomeBPM)
        activeProfileName = name
        isProfileModified = false
        loadedProfileSnapshot = profile
        // Re-apply settings to the engine if active
        if isActive {
            for (uid, settings) in deviceSettings where settings.isEnabled {
                outputEngine.updateVolume(for: uid, volume: settings.volume)
                outputEngine.updateDelay(for: uid, ms: settings.delayMs)
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
        checkProfileModified()
    }

    /// Start acoustic calibration using the MacBook mic.
    /// Measures real speaker latency by playing chirps and listening.
    func startAcousticCalibration() async {
        guard isActive else { return }
        let devices = deviceDiscovery.devices.compactMap { device -> (uid: String, name: String)? in
            // Exclude the capture device
            if let capID = systemCapturer.activeCaptureDeviceID, device.id == capID { return nil }
            let settings = deviceSettings[device.uid]
            guard settings?.isEnabled ?? true else { return nil }
            return (uid: device.uid, name: device.name)
        }
        await calibrator.startCalibration(deviceUIDs: devices)
    }

    /// Apply calibration results (set delays from acoustic measurement).
    func applyCalibrationResults() {
        calibrator.applyResults(to: self)
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

        for (uid, delayMs) in compensated {
            deviceSettings[uid]?.delayMs = delayMs
        }
        isAutoSyncing = false
        return compensated
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
        DLog("[AppState] Settings saved (\(deviceSettings.count) devices, \(profiles.count) profiles)")
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
        networkProfileMap = defaults.dictionary(forKey: "com.audiosync.networkProfileMap") as? [String: String] ?? [:]
        // Apply master volume to engine
        outputEngine.setMasterVolume(masterVolume)
        // Auto-load active profile on launch
        if let name = activeProfileName, profiles[name] != nil {
            loadProfile(name: name)
        }
    }

}
