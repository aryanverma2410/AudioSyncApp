import SwiftUI

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showProfileSheet = false
    @State private var showNewProfileAlert = false
    @State private var newProfileName = ""

    var body: some View {
        HStack(spacing: 0) {
            // ── Sidebar ──
            sidebar
                .frame(width: 240)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // ── Main Content ──
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App header
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("AudioSync")
                    .font(.headline)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.isActive ? Color.green : Color.red.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(appState.isActive ? "Routing Active" : "Inactive")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if appState.isActive {
                    Label {
                        Text("Capture: \(appState.systemCapturer.captureMethod.rawValue)")
                    } icon: {
                        Image(systemName: appState.systemCapturer.captureMethod == .coreAudio ? "hifispeaker.and.signal" : "capture.viewfinder")
                            .foregroundColor(appState.systemCapturer.captureMethod == .coreAudio ? .green : .orange)
                            .font(.caption2)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                Spacer()
                if appState.isActive {
                    Text("\(appState.outputEngine.activeDeviceCount) device\(appState.outputEngine.activeDeviceCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            Divider()

            // Profiles section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("PROFILES")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    Spacer()
                    Button {
                        showNewProfileAlert = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                if appState.profileManager.profiles.isEmpty {
                    Text("No profiles yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(appState.profileManager.profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            // Bottom controls
            VStack(spacing: 12) {
                Divider()
                    .padding(.horizontal, 16)

                // Master toggle
                Button {
                    if appState.isActive {
                        appState.stop()
                    } else {
                        Task { await appState.start() }
                    }
                } label: {
                    HStack {
                        Image(systemName: appState.isActive ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title3)
                        Text(appState.isActive ? "Stop Routing" : "Start Routing")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(appState.isActive ? Color.red.opacity(0.1) : Color.accentColor.opacity(0.1))
                    .foregroundColor(appState.isActive ? .red : .accentColor)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                // Test All Speakers button
                Button {
                    appState.testToneAll()
                } label: {
                    HStack {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.title3)
                        Text("Test All Speakers")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.1))
                    .foregroundColor(.orange)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .alert("New Profile", isPresented: $showNewProfileAlert) {
            TextField("Profile name", text: $newProfileName)
            Button("Create") {
                if !newProfileName.isEmpty {
                    _ = appState.profileManager.createProfile(named: newProfileName)
                }
                newProfileName = ""
            }
            Button("Cancel", role: .cancel) {
                newProfileName = ""
            }
        } message: {
            Text("Enter a name for the new audio profile.")
        }
    }

    private func profileRow(_ profile: AudioProfile) -> some View {
        let isSelected = appState.profileManager.selectedProfile?.id == profile.id
        return Button {
            appState.applyProfile(profile)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(profile.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Error banner
                if let error = appState.errorMessage {
                    errorBanner(error)
                }

                // Capture error
                if let captureError = appState.systemCapturer.captureError {
                    captureErrorBanner(captureError)
                }

                // Header
                headerSection

                // Device list
                devicesSection
            }
            .padding(24)
        }
        .background(Color(nsColor: .controlBackgroundColor))
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

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output Devices")
                .font(.title2)
                .fontWeight(.bold)

            HStack(spacing: 16) {
                Label {
                    Text("\(appState.deviceDiscovery.devices.count) detected")
                } icon: {
                    Image(systemName: "hifispeaker.and.signal")
                        .foregroundColor(.accentColor)
                }
                .font(.subheadline)
                .foregroundColor(.secondary)

                if appState.outputEngine.isRunning {
                    Label {
                        Text("Engine running")
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundColor(.green)
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }

                if appState.isActive {
                    Label {
                        Text("Capture: \(appState.systemCapturer.captureMethod.rawValue)")
                    } icon: {
                        Image(systemName: appState.systemCapturer.captureMethod == .coreAudio ? "hifispeaker.and.signal" : "capture.viewfinder")
                            .foregroundColor(appState.systemCapturer.captureMethod == .coreAudio ? .green : .orange)
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }

                if appState.outputEngine.activeDeviceCount > 0 {
                    Label {
                        Text("\(appState.outputEngine.activeDeviceCount) active")
                    } icon: {
                        Image(systemName: "speaker.wave.2")
                            .foregroundColor(.accentColor)
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    appState.deviceDiscovery.refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Devices Section

    private var devicesSection: some View {
        Group {
            if appState.deviceDiscovery.devices.isEmpty {
                emptyStateView
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(appState.deviceDiscovery.devices) { device in
                        DeviceControlCard(device: device)
                            .environmentObject(appState)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 40)

            Image(systemName: "hifispeaker")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Output Devices Found")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Connect a speaker, headphones, or Bluetooth device\nto begin routing audio.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

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
    @State private var isExpanded = true

    private var settings: DeviceSettings {
        appState.deviceSettings[device.uid] ?? (device.transportType.isBluetooth ? .defaultBluetooth : DeviceSettings())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 12) {
                // Device icon
                Image(systemName: device.transportType.iconName)
                    .font(.title2)
                    .foregroundColor(device.transportType.color)
                    .frame(width: 32)

                // Device info
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        // Transport type badge
                        Text(device.transportType.rawValue)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(device.transportType.color.opacity(0.15))
                            .cornerRadius(4)

                        // Sample rate
                        Text("\(Int(device.sampleRate)) Hz")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        // Latency
                        if device.nominalLatency > 0 {
                            Text("\(Int(device.nominalLatency)) ms latency")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                // Enable toggle
                Toggle("", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { appState.toggleDevice(device.uid, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, isExpanded && settings.isEnabled ? 8 : 14)

            // Expanded controls
            if settings.isEnabled {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                        .padding(.horizontal, 16)

                    // Delay control
                    delayControl

                    // Volume control
                    volumeControl

                    // Mute button
                    muteControl
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(settings.isEnabled ? device.transportType.color.opacity(0.2) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Delay Control

    private var delayControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Delay", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text(String(format: "%.0f ms", Double(settings.delayMs)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            }

            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(settings.delayMs) },
                        set: { appState.updateDelay(device.uid, ms: Float($0)) }
                    ),
                    in: 0...500,
                    step: 5
                )

                Button {
                    appState.updateDelay(device.uid, ms: 0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reset delay to 0 ms")
            }
        }
    }

    // MARK: - Volume Control

    private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Volume", systemImage: "speaker.wave.2")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(Int(settings.volume * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            }

            Slider(
                value: Binding(
                    get: { Double(settings.volume) },
                    set: { appState.updateVolume(device.uid, volume: Float($0)) }
                ),
                in: 0...1,
                step: 0.01
            )
        }
    }

    // MARK: - Mute Control

    private var muteControl: some View {
        HStack {
            Button {
                appState.updateMute(device.uid, isMuted: !settings.isMuted)
            } label: {
                Label(
                    settings.isMuted ? "Unmute" : "Mute",
                    systemImage: settings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
                .font(.subheadline)
                .foregroundColor(settings.isMuted ? .red : .primary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if settings.isMuted {
                Text("Device is muted")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()

            // Test tone button — injects a 440Hz beep directly into this device's ring buffer
            Button {
                appState.testTone(for: device.uid)
            } label: {
                Label("Test", systemImage: "waveform.badge.megaphone")
                    .font(.caption2)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Play a test tone to this device")

            // Quick presets for Bluetooth
            if device.transportType.isBluetooth {
                HStack(spacing: 4) {
                    Text("Presets:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button("0ms") { appState.updateDelay(device.uid, ms: 0) }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    Button("150ms") { appState.updateDelay(device.uid, ms: 150) }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    Button("200ms") { appState.updateDelay(device.uid, ms: 200) }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                    Button("300ms") { appState.updateDelay(device.uid, ms: 300) }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}
