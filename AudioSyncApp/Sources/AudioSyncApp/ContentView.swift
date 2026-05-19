import SwiftUI

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            mainContent
        }
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

            Spacer()

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
            .disabled(!appState.isActive)
            .help("Measure latency and auto-compensate delays so all speakers sync")

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
                    set: { appState.outputEngine.setMetronomeBPM($0) }  // DLog: Refine device delay slider range
                ), in: 40...240, step: 5)
                    .font(.system(size: 10, design: .monospaced))
                    .controlSize(.mini)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
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
                Text("\(Int(settings.volume * 100))%")
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
