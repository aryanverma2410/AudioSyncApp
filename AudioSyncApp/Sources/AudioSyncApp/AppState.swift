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

        // Step 4: Save current system volumes for ALL devices before overriding to max
        DLog("Saving current system volumes...")
        outputEngine.saveSystemVolumes(devices: deviceDiscovery.devices, captureDeviceID: systemCapturer.activeCaptureDeviceID)

        // Step 4b: Set ALL output devices to max volume (including disabled ones),
        // but EXCLUDE the capture device (BlackHole) — changing its volume/mute
        // can interfere with its capture IOProc.
        for device in deviceDiscovery.devices where device.id != captureDeviceID {
            outputEngine.setDeviceVolumeToMax(device.id)
        }

        // Step 5: Configure the output engine (sets per-device volumes to max)
        do {
            try outputEngine.configure(devices: devicesWithSettings)
        } catch {
            errorMessage = "Failed to configure audio engine: \(error.localizedDescription)"
            DLog("ERROR: configure failed — \(error)")
            systemCapturer.stopCapture()
            return
        }

        // Step 5b: Set the current default output device volume to max (NC slider)
        outputEngine.setDefaultDeviceVolumeMax()

        // Step 6: Start the output engine (wrapped in crash guard)
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
        outputEngine.restoreSystemVolumes()
        isActive = false
        DLog("Routing stopped.")
    }

    // MARK: - Device Controls

    func toggleDevice(_ uid: String, enabled: Bool) {
        ensureSettingsExist(for: uid)
        if var s = deviceSettings[uid] {
            s.isEnabled = enabled
            deviceSettings[uid] = s  // replace entry → triggers @Published
        }
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
    /// Handles three cases: brand-new devices, reconnected BT devices (same UID, new ID),
    /// and stale devices that need teardown.
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
        if var s = deviceSettings[uid] {
            s.delayMs = ms
            deviceSettings[uid] = s  // replace entry → triggers @Published
        }
        outputEngine.updateDelay(for: uid, ms: ms)
        checkProfileModified()
    }

    func updateVolume(_ uid: String, volume: Float) {
        ensureSettingsExist(for: uid)
        if var s = deviceSettings[uid] {
            s.volume = volume
            deviceSettings[uid] = s  // replace entry → triggers @Published
        }
        outputEngine.updateVolume(for: uid, volume: volume)
        checkProfileModified()
    }

    func updateMute(_ uid: String, isMuted: Bool) {
        ensureSettingsExist(for: uid)
        if var s = deviceSettings[uid] {
            s.isMuted = isMuted
            deviceSettings[uid] = s  // replace entry → triggers @Published
        }
        outputEngine.updateMute(for: uid, isMuted: isMuted)
        checkProfileModified()
    }

    /// Set all enabled, non-muted devices to a specific volume level.
    func setAllVolumeToLevel(_ targetVolume: Float) {
        for (uid, _) in deviceSettings where deviceSettings[uid]?.isEnabled == true && deviceSettings[uid]?.isMuted == false {
            if var s = deviceSettings[uid] {
                s.volume = targetVolume
                deviceSettings[uid] = s  // replace entry → triggers @Published
            }
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

    /// Stored master volume before fade-out began (restored on cancel/expiry).
    private var preFadeMasterVolume: Float? = nil

    func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        // Restore volume if cancelling while fading
        if let saved = preFadeMasterVolume {
            setMasterVolume(saved)  // syncs both @Published + engine
            preFadeMasterVolume = nil
        }
        if let mins = minutes {
            sleepTimerMinutes = mins
            sleepTimerRemaining = mins * 60
            preFadeMasterVolume = masterVolume
            NotificationCenter.default.post(name: Notification.Name("com.audiosync.sleepTimerTick"), object: nil, userInfo: ["remaining": sleepTimerRemaining])
            sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                Task { @MainActor [weak self] in
                    guard let self else { t.invalidate(); return }
                    self.sleepTimerRemaining -= 1

                    // Post countdown for menu bar display
                    NotificationCenter.default.post(name: Notification.Name("com.audiosync.sleepTimerTick"), object: nil, userInfo: ["remaining": self.sleepTimerRemaining])

                    // Gradual fade in last 2 minutes (120 seconds)
                    let fadeSeconds: Float = 120
                    if Float(self.sleepTimerRemaining) <= fadeSeconds, let savedVol = self.preFadeMasterVolume {
                        let progress = Float(self.sleepTimerRemaining) / fadeSeconds // 1.0 → 0.0
                        self.setMasterVolume(savedVol * progress)
                    }

                    if self.sleepTimerRemaining <= 0 {
                        self.setMasterVolume(0)
                        self.sleepTimerMinutes = nil
                        self.sleepTimerRemaining = 0
                        NotificationCenter.default.post(name: Notification.Name("com.audiosync.sleepTimerTick"), object: nil, userInfo: ["remaining": 0])
                        t.invalidate()
                        DLog("[AppState] Sleep timer expired — volume faded to 0 (routing still active)")
                    }
                }
            }
        } else {
            sleepTimerMinutes = nil
            sleepTimerRemaining = 0
            preFadeMasterVolume = nil
            NotificationCenter.default.post(name: Notification.Name("com.audiosync.sleepTimerTick"), object: nil, userInfo: ["remaining": 0])
        }
    }

    // MARK: - DSP Controls

    func updateDeviceEQ(_ uid: String, bass: Float, treble: Float) {
        ensureSettingsExist(for: uid)
        if var s = deviceSettings[uid] {
            s.bass = bass
            s.treble = treble
            deviceSettings[uid] = s  // triggers @Published
        }
        outputEngine.updateEQ(for: uid, bass: bass, treble: treble, mid: 0)
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
        if var s = deviceSettings[uid] {
            s.isSubwoofer = enabled
            s.crossoverHz = crossoverHz
            deviceSettings[uid] = s  // replace entry → triggers @Published
        }
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
        // Get current SSID via airport CLI (avoids CoreWLAN entitlement complexity)
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
            if var s = deviceSettings[uid] {
                s.delayMs = delayMs
                deviceSettings[uid] = s  // replace entry → triggers @Published
            }
        }
        isAutoSyncing = false
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

    // MARK: - Persistence (file-based, survives app rebuilds)

    private static var storageDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AudioSyncApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var settingsFileURL: URL { storageDir.appendingPathComponent("settings.json") }

    private struct PersistedState: Codable {
        var deviceSettings: [String: DeviceSettings]
        var deviceOrder: [String]
        var profiles: [String: RoomProfile]
        var activeProfileName: String?
        var masterVolume: Float
        var networkProfileMap: [String: String]
    }

    private func saveSettings() {
        let state = PersistedState(
            deviceSettings: deviceSettings,
            deviceOrder: deviceOrder,
            profiles: profiles,
            activeProfileName: activeProfileName,
            masterVolume: masterVolume,
            networkProfileMap: networkProfileMap
        )
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: Self.settingsFileURL, options: .atomic)
            DLog("[AppState] Settings saved (\(deviceSettings.count) devices, \(profiles.count) profiles)")
        } catch {
            DLog("[AppState] Failed to save settings: \(error)")
        }
    }

    private func restoreSettings() {
        let url = Self.settingsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            DLog("[AppState] No saved settings file — starting fresh")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let saved = try JSONDecoder().decode(PersistedState.self, from: data)
            deviceSettings = saved.deviceSettings
            deviceOrder = saved.deviceOrder
            profiles = saved.profiles
            activeProfileName = saved.activeProfileName
            masterVolume = saved.masterVolume > 0 ? saved.masterVolume : 1.0
            networkProfileMap = saved.networkProfileMap
            DLog("[AppState] Restored \(saved.deviceSettings.count) devices, \(saved.profiles.count) profiles from \(url.path)")
            outputEngine.setMasterVolume(masterVolume)
            if let name = activeProfileName, profiles[name] != nil {
                loadProfile(name: name)
            }
        } catch {
            DLog("[AppState] Failed to restore settings: \(error)")
        }
    }

}
