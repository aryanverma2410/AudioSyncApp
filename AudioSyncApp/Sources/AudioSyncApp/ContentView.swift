import SwiftUI

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var newProfileName = ""
    @State private var showSaveProfileSheet = false
    @State private var showSetupWizard = false
    @State private var showHealthDashboard = false
    @State private var showMiniWidget = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            mainContent
        }
        .background(
            Group {
                // Keyboard shortcuts for profile switching (⌘1–5)
                Button("") { selectProfileAt(0) }
                    .keyboardShortcut("1", modifiers: .command)
                    .hidden()
                Button("") { selectProfileAt(1) }
                    .keyboardShortcut("2", modifiers: .command)
                    .hidden()
                Button("") { selectProfileAt(2) }
                    .keyboardShortcut("3", modifiers: .command)
                    .hidden()
                Button("") { selectProfileAt(3) }
                    .keyboardShortcut("4", modifiers: .command)
                    .hidden()
                Button("") { selectProfileAt(4) }
                    .keyboardShortcut("5", modifiers: .command)
                    .hidden()
            }
        )
        .sheet(isPresented: $showSetupWizard) {
            SetupWizardSheet(setupAssistant: appState.setupAssistant, isPresented: $showSetupWizard)
        }
        .sheet(isPresented: $showHealthDashboard) {
            HealthDashboardView()
                .environmentObject(appState)
        }
        .onChange(of: showMiniWidget) { show in
            if show {
                MiniWidgetPanelController.shared.show(appState)
            } else {
                MiniWidgetPanelController.shared.hide()
            }
        }
    }

    private func selectProfileAt(_ index: Int) {
        let sortedNames = appState.profiles.keys.sorted()
        guard index < sortedNames.count else { return }
        appState.loadProfile(name: sortedNames[index])
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            // App identity
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("AudioSync")
                    .font(.headline)
            }

            Separator()

            // Profile picker
            Menu {
                Button {
                    showSaveProfileSheet = true
                } label: {
                    Label("Save Current as Profile…", systemImage: "plus")
                }

                if appState.activeProfileName != nil && appState.isProfileModified {
                    Button {
                        if let name = appState.activeProfileName {
                            appState.saveProfile(name: name)
                        }
                    } label: {
                        Label("Update Current Profile", systemImage: "arrow.clockwise")
                    }
                }

                Divider()

                if appState.profiles.isEmpty {
                    Text("No saved profiles").italic()
                } else {
                    ForEach(appState.profiles.keys.sorted(), id: \.self) { name in
                        Button {
                            appState.loadProfile(name: name)
                        } label: {
                            HStack {
                                Text(name)
                                if appState.activeProfileName == name {
                                    Image(systemName: "checkmark")
                                }
                                Spacer()
                            }
                        }
                        Button {
                            appState.saveProfile(name: name)
                        } label: {
                            Label("Update", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            appState.deleteProfile(name: name)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption)
                    HStack(spacing: 3) {
                        Text(appState.activeProfileName ?? "Profiles")
                            .font(.caption)
                            .lineLimit(1)
                        if appState.isProfileModified {
                            Image(systemName: "asterisk.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Save, load, or delete room profiles (⌘1–5 for quick switch)")
            .popover(isPresented: $showSaveProfileSheet) {
                saveProfilePopover
            }

            Separator()

            // Status pill
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.isActive ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(appState.isActive ? "Routing" : "Off")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(appState.isActive ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(appState.isActive ? Color.green.opacity(0.1) : Color.gray.opacity(0.08))
            )

            if appState.isActive {
                HStack(spacing: 4) {
                    Image(systemName: "hifispeaker.and.signal")
                        .font(.caption2)
                    Text("\(appState.outputEngine.activeDeviceCount) active")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: appState.systemCapturer.captureMethod == .coreAudio ? "hifispeaker.and.signal" : "capture.viewfinder")
                        .font(.caption2)
                    Text(appState.systemCapturer.captureMethod.rawValue)
                        .font(.caption2)
                }
                .foregroundColor(appState.systemCapturer.captureMethod == .coreAudio ? .green : .orange)
            }

            // Auto-sync indicator
            if appState.isAutoSyncing {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Measuring…")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            // Karaoke toggle (mutually exclusive with Voice Isolation)
            Button {
                appState.setAudioMode(appState.audioMode == .karaoke ? .normal : .karaoke)
            } label: {
                Label("Karaoke", systemImage: "music.mic")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(appState.audioMode == .karaoke ? .purple : .accentColor)
            .help("Karaoke: reduces vocals, keeps instruments  (⌘⇧K)")

            // Voice Isolation toggle (mutually exclusive with Karaoke)
            Button {
                appState.setAudioMode(appState.audioMode == .vocalBoost ? .normal : .vocalBoost)
            } label: {
                Label("Voice Iso", systemImage: "person.wave.2")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(appState.audioMode == .vocalBoost ? .green : .accentColor)
            .help("Voice Isolation: boosts vocals, reduces background  (⌘⇧K to toggle off)")

            Separator()

            // Reverb preset picker
            Picker("Reverb", selection: Binding(
                get: { appState.reverbPreset },
                set: { appState.setReverb($0) }
            )) {
                ForEach(ReverbPreset.allCases, id: \.self) { preset in
                    Label(preset.label, systemImage: preset.icon).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 90)
            .help("Reverb effect preset")

            Separator()

            // Sleep timer menu
            Menu {
                Button("Off") { appState.setSleepTimer(minutes: nil) }
                Divider()
                ForEach([15, 30, 45, 60, 90], id: \.self) { mins in
                    Button("\(mins) min") { appState.setSleepTimer(minutes: mins) }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: appState.sleepTimerMinutes != nil ? "timer" : "timer")
                        .font(.caption)
                    if appState.sleepTimerMinutes != nil {
                        Text("\(appState.sleepTimerRemaining / 60):\(String(format: "%02d", appState.sleepTimerRemaining % 60))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Sleep timer: auto-stop routing after N minutes  (⌘⇧Space to toggle 30 min)")

            Separator()

            // Health dashboard button
            Button {
                showHealthDashboard = true
            } label: {
                Image(systemName: "heart.text.clipboard")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Device health: buffer fill, underruns, drift, latency")

            // Mini widget toggle
            Button {
                showMiniWidget.toggle()
            } label: {
                Image(systemName: showMiniWidget ? "rectangle.pipeline" : "rectangle.split.2x1")
                    .font(.caption)
                    .foregroundColor(showMiniWidget ? .accentColor : .secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Toggle mini floating widget")

            Separator()

            // Master volume
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(appState.masterVolume) },
                        set: { appState.setMasterVolume(Float($0)) }
                    ),
                    in: 0...1,
                    step: 0.01
                )
                .frame(width: 80)
                Text("\(Int(appState.masterVolume * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .help("Master volume — proportionally scales all speakers")

            Separator()

            // Action buttons
            Button {
                appState.testToneAll()
            } label: {
                Label("Test All", systemImage: "speaker.wave.2.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!appState.isActive)
            .help("Play a test beep to all speakers to verify they're working")

            Button {
                let result = appState.autoDelayCompensate()
                for (uid, delayMs) in result {
                    appState.updateDelay(uid, ms: delayMs)
                }
            } label: {
                Label("Auto Sync", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!appState.isActive || appState.isAutoSyncing)
            .help("Measure latency and auto-compensate delays so all speakers sync")

            Button {
                Task { await appState.startAcousticCalibration() }
            } label: {
                Label("Calibrate", systemImage: "mic.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!appState.isActive || appState.calibrator.state == .measuring || appState.calibrator.state == .crossChecking)
            .help("Acoustic calibration: use the MacBook mic to measure real speaker delays")

            Separator()

            // Metronome
            HStack(spacing: 4) {
                Button {
                    if appState.outputEngine.isMetronomeOn {
                        appState.outputEngine.stopMetronome()
                    } else {
                        appState.outputEngine.startMetronome(bpm: appState.outputEngine.metronomeBPM)
                    }
                } label: {
                    Image(systemName: appState.outputEngine.isMetronomeOn ? "metronome.fill" : "metronome")
                        .font(.caption)
                        .foregroundColor(appState.outputEngine.isMetronomeOn ? .accentColor : .secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!appState.isActive)
                .help("Toggle metronome click")

                Stepper("\(appState.outputEngine.metronomeBPM)", value: Binding(
                    get: { appState.outputEngine.metronomeBPM },
                    set: { appState.outputEngine.setMetronomeBPM($0) }
                ), in: 40...240, step: 5)
                    .font(.system(size: 10, design: .monospaced))
                    .controlSize(.mini)
                    .help("Metronome tempo (BPM)")
            }

            Button {
                appState.deviceDiscovery.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh device list")

            // Setup wizard button (shows when not fully set up)
            if !appState.setupAssistant.isFullySetup {
                Button {
                    showSetupWizard = true
                } label: {
                    Label("Setup", systemImage: "gear.badge.checkmark")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Run first-time setup: install BlackHole, create Multi-Output device")
            }

            Separator()

            // Master routing toggle
            Button {
                if appState.isActive {
                    appState.stop()
                } else {
                    Task { await appState.start() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appState.isActive ? "stop.fill" : "play.fill")
                    Text(appState.isActive ? "Stop" : "Start")
                        .fontWeight(.semibold)
                }
                .font(.callout)
                .frame(width: 72, height: 28)
                .background(appState.isActive ? Color.red : Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help(appState.isActive ? "Stop audio routing to all speakers" : "Start routing system audio to all speakers")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Save Profile Popover

    private var saveProfilePopover: some View {
        VStack(spacing: 12) {
            Text("Save Room Profile")
                .font(.headline)
            TextField("Profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            HStack(spacing: 8) {
                Button("Cancel") {
                    showSaveProfileSheet = false
                    newProfileName = ""
                }
                .buttonStyle(.bordered)
                Button("Save") {
                    guard !newProfileName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    appState.saveProfile(name: newProfileName.trimmingCharacters(in: .whitespaces))
                    showSaveProfileSheet = false
                    newProfileName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 260)
    }

    // MARK: - Separator

    private func Separator() -> some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.gray.opacity(0.3))
            .frame(width: 1, height: 20)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Errors
                    if let error = appState.errorMessage {
                        errorBanner(error)
                    }
                    if let captureError = appState.systemCapturer.captureError {
                        captureErrorBanner(captureError)
                    }

                    // Restart bar (only when active)
                    if appState.isActive {
                        restartBar
                    }

                    // Calibration panel (when calibrating or done)
                    if appState.calibrator.state != .idle {
                        calibrationPanel
                    }

                    // Device grid
                    if appState.deviceDiscovery.devices.isEmpty {
                        emptyStateView
                    } else {
                        deviceGrid
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Calibration Panel

    private var calibrationPanel: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundColor(.accentColor)
                Text("Acoustic Calibration")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                // State indicator
                switch appState.calibrator.state {
                case .requestingPermission:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Requesting mic permission…")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                case .measuring:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Measuring speaker \(appState.calibrator.currentDeviceIndex + 1)/\(appState.calibrator.totalDevices)…")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                case .crossChecking:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Cross-checking…")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                case .done:
                    Text("Complete")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                case .failed:
                    Text("Failed")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.red)
                default:
                    EmptyView()
                }

                // Cancel / Dismiss
                if appState.calibrator.state == .measuring || appState.calibrator.state == .crossChecking {
                    Button("Cancel") { appState.calibrator.cancelCalibration() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

            // Error message
            if let error = appState.calibrator.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Results table
            let orderedResults = appState.calibrator.results.values.sorted { ($0.arrivalMs ?? 0) < ($1.arrivalMs ?? 0) }
            if !orderedResults.isEmpty {
                VStack(spacing: 4) {
                    ForEach(orderedResults) { result in
                        HStack {
                            Text(result.deviceName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)

                            Spacer()

                            if let arrival = result.arrivalMs {
                                Text(String(format: "%.0f ms", arrival))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("—")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }

                            if let delay = result.recommendedDelayMs {
                                Text("→ \(String(format: "%.0f", delay)) ms delay")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(delay > 0 ? .accentColor : .green)
                            }

                            // Confidence dot
                            if result.isMeasured {
                                Circle()
                                    .fill(result.confidence > 0.7 ? .green : result.confidence > 0.3 ? .yellow : .red)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(4)
                    }
                }
            }

            // Apply button
            if appState.calibrator.state == .done {
                HStack {
                    Button {
                        appState.applyCalibrationResults()
                    } label: {
                        Label("Apply Delays", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        appState.calibrator.state = .idle
                    } label: {
                        Text("Dismiss")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Restart Bar

    private var restartBar: some View {
        HStack {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
            Text("New speakers auto-join when connected.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                Task { await appState.restartRouting() }
            } label: {
                Label("Restart Sync", systemImage: "arrow.clockwise.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Device Grid

    private var deviceGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(minimum: 280), spacing: 12),
            GridItem(.flexible(minimum: 280), spacing: 12),
        ], alignment: .leading, spacing: 12) {
            ForEach(orderedDevices) { device in
                DeviceControlCard(device: device)
                    .environmentObject(appState)
                    .onDrag { NSItemProvider(object: device.uid as NSString) }
                    .onDrop(of: [.text], delegate: DeviceDropDelegate(targetUID: device.uid, appState: appState))
            }
        }
    }

    /// Devices sorted by user's drag-reorder preference
    private var orderedDevices: [AudioOutputDevice] {
        let devices = appState.deviceDiscovery.devices
        let order = appState.deviceOrder
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

    // MARK: - Error Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button {
                appState.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    private func captureErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundColor(.red)
            Text(message)
                .font(.subheadline)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 60)
            Image(systemName: "hifispeaker")
                .font(.system(size: 56))
                .foregroundStyle(.secondary.opacity(0.4))

            VStack(spacing: 6) {
                Text("No Output Devices Found")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("Connect a speaker, headphones, or Bluetooth device\nto begin routing audio.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                appState.deviceDiscovery.refreshDevices()
            } label: {
                Label("Scan for Devices", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

// MARK: - Device Control Card

struct DeviceControlCard: View {
    let device: AudioOutputDevice
    @EnvironmentObject var appState: AppState

    private var settings: DeviceSettings {
        appState.deviceSettings[device.uid] ?? (device.transportType.isBluetooth ? .defaultBluetooth : DeviceSettings())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Card Header ──
            cardHeader
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, settings.isEnabled ? 8 : 10)

            // ── Controls (only when enabled) ──
            if settings.isEnabled {
                VStack(spacing: 10) {
                    volumeSection
                    vuMeter
                    delaySection
                    eqSection
                    actionBar
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(settings.isEnabled ? device.transportType.color.opacity(0.15) : Color.gray.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(settings.isEnabled ? 0.05 : 0.01), radius: 6, y: 2)
        .opacity(settings.isEnabled ? 1.0 : 0.6)
    }

    // MARK: - Card Background

    private var cardBackground: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            // Accent stripe at top
            RoundedRectangle(cornerRadius: 0)
                .fill(device.transportType.color.opacity(settings.isEnabled ? 0.08 : 0.02))
                .frame(height: 4)
        }
    }

    // MARK: - Card Header

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            // Device icon
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(device.transportType.color.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: device.transportType.iconName)
                    .font(.callout)
                    .foregroundColor(device.transportType.color)
            }

            // Device name + badges
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    transportBadge

                    if device.nominalLatency > 0 {
                        Text("\(Int(device.nominalLatency))ms")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if device.transportType.isBluetooth {
                        Text("BT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(3)
                    }

                    // End-to-end latency (when routing)
                    if appState.isActive {
                        let latency = appState.outputEngine.latency(for: device.uid)
                        if latency > 0 {
                            Text(String(format: "%.0fms", latency))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(latency > 300 ? .red : latency > 150 ? .orange : .green)
                        }
                    }

                    // Subwoofer badge
                    if settings.isSubwoofer {
                        Text("SUB")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.12))
                            .cornerRadius(3)
                    }
                }
            }

            Spacer()

            // Mute toggle
            if settings.isEnabled {
                Button {
                    appState.updateMute(device.uid, isMuted: !settings.isMuted)
                } label: {
                    Image(systemName: settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.callout)
                        .foregroundColor(settings.isMuted ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(settings.isMuted ? "Unmute" : "Mute")
            }

            // Enable toggle
            Toggle("", isOn: Binding(
                get: { settings.isEnabled },
                set: { appState.toggleDevice(device.uid, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(settings.isEnabled ? "Disable this speaker from routing" : "Enable this speaker for routing")
        }
    }

    // MARK: - Transport Badge

    private var transportBadge: some View {
        Text(device.transportType.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(device.transportType.color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(device.transportType.color.opacity(0.1))
            .cornerRadius(3)
    }

    // MARK: - Volume Section

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Volume", systemImage: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                let volDb: String = settings.volume > 0.001 ? String(format: "%+.0fdB", 20 * log10(settings.volume)) : "-∞"
                Text("\(Int(settings.volume * 100))%  \(volDb)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(settings.isMuted ? .red : .primary)
            }

            Slider(
                value: Binding(
                    get: { Double(settings.volume) },
                    set: { appState.updateVolume(device.uid, volume: Float($0)) }
                ),
                in: 0...1,
                step: 0.01
            )
            .tint(settings.isMuted ? .red : device.transportType.color)
        }
    }

    // MARK: - VU Meter

    private var vuMeter: some View {
        HStack(spacing: 5) {
            GeometryReader { geo in
                let level = appState.vuLevels[device.uid] ?? 0
                let dbFloor: Float = -60
                let linearDb = level > 0 ? 20 * log10(level) : dbFloor
                let clampedDb = max(linearDb, dbFloor)
                let fraction = CGFloat((clampedDb - dbFloor) / (0 - dbFloor))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.12))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .green,
                                    level > 0.5 ? .yellow : .green,
                                    level > 0.9 ? .red : .orange
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geo.size.width * fraction, 0))
                }
            }
            .frame(height: 4)

            let lvl = appState.vuLevels[device.uid] ?? 0
            let db = lvl > 0 ? 20 * log10(lvl) : -60
            Text(lvl > 0.001 ? String(format: "%+.0fdB", db) : " -∞")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - Delay Section

    private var delaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Delay", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f ms", Double(settings.delayMs)))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(settings.delayMs > 0 ? .accentColor : .secondary)
            }

            HStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { Double(settings.delayMs) },
                        set: { appState.updateDelay(device.uid, ms: Float($0)) }
                    ),
                    in: 0...Double(DeviceSettings.maxDelayMs),
                    step: 5
                )
                .tint(.accentColor)

                TextField("ms", value: Binding(
                    get: { Double(settings.delayMs) },
                    set: { appState.updateDelay(device.uid, ms: Float(min(max($0, 0), Double(DeviceSettings.maxDelayMs)))) }
                ), format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 48)
                    .font(.system(size: 11, design: .monospaced))

                Button {
                    appState.updateDelay(device.uid, ms: 0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset delay to 0ms")
            }
        }
    }

    // MARK: - EQ Section

    private var eqSection: some View {
        DisclosureGroup("EQ") {
            VStack(spacing: 8) {
                // Bass
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Bass", systemImage: "speaker.wave.1")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%+.1fdB", settings.bass * 6))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(settings.bass != 0 ? .accentColor : .secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.bass) },
                        set: { appState.updateDeviceEQ(device.uid, bass: Float($0), treble: settings.treble) }
                    ), in: -1...1, step: 0.05)
                    .tint(.accentColor)
                }
                // Treble
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Treble", systemImage: "speaker.wave.3")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%+.1fdB", settings.treble * 6))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(settings.treble != 0 ? .accentColor : .secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.treble) },
                        set: { appState.updateDeviceEQ(device.uid, bass: settings.bass, treble: Float($0)) }
                    ), in: -1...1, step: 0.05)
                    .tint(.accentColor)
                }
                // Reset
                Button {
                    appState.updateDeviceEQ(device.uid, bass: 0, treble: 0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset EQ to flat")
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            // Test tone
            Button {
                appState.testTone(for: device.uid)
            } label: {
                Label("Test", systemImage: "waveform.badge.megaphone")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Play a test tone on this speaker only")

            // Subwoofer toggle
            Toggle(isOn: Binding(
                get: { settings.isSubwoofer },
                set: { appState.setSubwoofer(device.uid, enabled: $0, crossoverHz: settings.crossoverHz) }
            )) {
                Label("Sub", systemImage: "speaker.wave.1")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .help("Toggle subwoofer mode — applies low-pass filter")

            Spacer()

            if settings.isMuted {
                Text("Muted")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
            }
        }
    }
}

// MARK: - Setup Wizard Sheet

struct SetupWizardSheet: View {
    @ObservedObject var setupAssistant: SetupAssistant
    @Binding var isPresented: Bool
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "hifispeaker.and.signal")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                Text("AudioSync Setup")
                    .font(.title2.bold())
                Text("This wizard will configure your Mac for multi-speaker audio routing.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Steps overview
            VStack(alignment: .leading, spacing: 12) {
                SetupStepRow(
                    number: 1,
                    title: "Install BlackHole",
                    description: "Free virtual audio driver for system audio capture",
                    isDone: setupAssistant.findBlackHoleDevice() != nil,
                    isActive: setupAssistant.state == .installingBlackHole
                )
                SetupStepRow(
                    number: 2,
                    title: "Create Multi-Output Device",
                    description: "Routes audio to all speakers simultaneously",
                    isDone: setupAssistant.findAggregateDevice() != nil,
                    isActive: setupAssistant.state == .creatingAggregate
                )
                SetupStepRow(
                    number: 3,
                    title: "Set as Default Output",
                    description: "Makes the Multi-Output your Mac's audio output",
                    isDone: setupAssistant.state == .done,
                    isActive: setupAssistant.state == .settingDefault
                )
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))

            // Progress / Status
            if setupAssistant.state != .notStarted {
                VStack(spacing: 8) {
                    if case .failed(let msg) = setupAssistant.state {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    } else if setupAssistant.state == .done {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Setup complete!")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    } else {
                        ProgressView(value: setupAssistant.progress)
                            .progressViewStyle(.linear)
                        Text(setupAssistant.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Buttons
            HStack(spacing: 12) {
                if setupAssistant.state == .done {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                } else if case .failed(_) = setupAssistant.state {
                    Button("Close") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)

                    Button("Retry") {
                        Task { await setupAssistant.runSetup() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)

                    Button("Start Setup") {
                        isRunning = true
                        Task { await setupAssistant.runSetup() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning && setupAssistant.state != .notStarted)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

struct SetupStepRow: View {
    let number: Int
    let title: String
    let description: String
    let isDone: Bool
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.green : (isActive ? Color.accentColor : Color.gray.opacity(0.3)))
                    .frame(width: 28, height: 28)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                } else if isActive {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Device Drop Delegate (drag-to-reorder)

struct DeviceDropDelegate: DropDelegate {
    let targetUID: String
    let appState: AppState

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { draggedUID, _ in
            guard let draggedUID = draggedUID as? String else { return }
            Task { @MainActor in
                guard draggedUID != targetUID else { return }
                let order = appState.deviceOrder
                guard let from = order.firstIndex(of: draggedUID),
                      let to = order.firstIndex(of: targetUID) else { return }
                var newOrder = order
                newOrder.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                appState.deviceOrder = newOrder
            }
        }
        return true
    }
}
