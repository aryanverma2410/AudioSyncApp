import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var profileManager: AudioProfileManager

    var profile: AudioProfile
    @State private var editName: String
    @State private var isEditing = false
    @State private var deviceSettings: [String: DeviceSettings]

    init(profile: AudioProfile) {
        self.profile = profile
        self._editName = State(initialValue: profile.name)
        // Deep-copy settings so edits don't mutate the original until saved
        var initSettings: [String: DeviceSettings] = [:]
        for (key, val) in profile.deviceSettings {
            initSettings[key] = DeviceSettings(
                volume: val.volume,
                delayMs: val.delayMs,
                isMuted: val.isMuted,
                isSelected: val.isSelected
            )
        }
        _deviceSettings = State(initialValue: initSettings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                devicesSection
                Spacer()
                actionsSection
            }
            .padding()
        }
        .navigationTitle(profile.name)
        .onChange(of: deviceSettings) { _, newSettings in
            for dev in deviceManager.availableDevices {
                let key = dev.id.uuidString
                let settings = newSettings[key] ?? DeviceSettings()
                if settings.isSelected {
                    audioEngine.setDeviceSetting(key, isMuted: false)
                    audioEngine.setDeviceSetting(key, volume: settings.volume)
                    audioEngine.setDeviceSetting(key, delayMs: settings.delayMs)
                }
            }
        }
    }

    // ── Header ──

    private var headerSection: some View {
        HStack {
            Group {
                if isEditing {
                    TextField("Profile name", text: $editName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveName() }
                } else {
                    Text(editName)
                        .font(.title2)
                        .fontWeight(.semibold)
                }
            }

            Spacer()

            Button {
                if isEditing {
                    saveName()
                } else {
                    isEditing = true
                }
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
            }
            .buttonStyle(.borderless)

            Button {
                profileManager.deleteProfile(profile)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            .disabled(profileManager.profiles.count <= 1)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.windowBackgroundColor))
                .shadow(radius: 1)
        }
    }

    private func saveName() {
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            profileManager.renameProfile(profile, to: name)
            editName = name
        }
        isEditing = false
    }

    // ── Devices ──

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Output Devices")
                .font(.headline)

            if deviceManager.availableDevices.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundColor(.orange)
                        Text("No devices detected")
                        Text("Make sure your speakers are connected.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ForEach(deviceManager.availableDevices) { dev in
                    DeviceCard(device: dev, deviceSettings: $deviceSettings)
                        .environmentObject(audioEngine)
                        .environmentObject(profileManager)
                }
            }
        }
    }

    // ── Actions ──

    private var actionsSection: some View {
        HStack(spacing: 16) {
            Button {
                var profileSettings: [String: DeviceSettings] = [:]
                for dev in deviceManager.availableDevices {
                    let key = dev.id.uuidString
                    if let s = deviceSettings[key] {
                        profileSettings[key] = s
                    }
                }
                profile.deviceSettings = profileSettings
                audioEngine.applyProfile(profile)
                profileManager.selectProfile(profile)
            } label: {
                Label("Apply Settings", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)

            Button {
                _ = profileManager.saveCurrentState()
            } label: {
                Label("Save New Profile", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.windowBackgroundColor))
        }
    }
}

// ── Device Card ──

struct DeviceCard: View {
    let device: AudioDevice
    @Binding var deviceSettings: [String: DeviceSettings]

    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var profileManager: AudioProfileManager

    @State private var isSelected: Bool
    @State private var volume: Double
    @State private var delay: Double
    @State private var isMuted: Bool

    init(device: AudioDevice, deviceSettings: Binding<[String: DeviceSettings]>) {
        self.device = device
        self._deviceSettings = deviceSettings
        let key = device.id.uuidString
        let s = deviceSettings.wrappedValue[key] ?? DeviceSettings()
        _isSelected = State(initialValue: s.isSelected)
        _volume = State(initialValue: Double(s.volume))
        _delay = State(initialValue: Double(s.delayMs))
        _isMuted = State(initialValue: s.isMuted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row header
            HStack {
                Image(systemName: device.iconName)
                    .foregroundColor(device.connectionColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(device.connectionType)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(device.connectionColor.opacity(0.15))
                            .cornerRadius(4)
                        Text("\(Int(device.sampleRate)) Hz")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(Int(device.latency)) ms")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    isSelected.toggle()
                    applySetting()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }

            if isSelected {
                VStack(alignment: .leading, spacing: 10) {
                    // Volume slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Volume")
                            Spacer()
                            Text("\(Int(volume * 100))%")
                                .font(.caption2)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        Slider(value: $volume, in: 0...1, step: 0.01)
                            .onChange(of: volume) { applySetting() }
                    }

                    // Delay slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Delay")
                            Spacer()
                            Text(String(format: "%.1f ms", delay))
                                .font(.caption2)
                                .monospacedDigit()
                                .frame(width: 60, alignment: .trailing)
                        }
                        HStack(spacing: 8) {
                            Slider(value: $delay, in: -1000...1000, step: 0.1)
                                .onChange(of: delay) { applySetting() }

                            Button {
                                delay = 0
                                applySetting()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .help("Reset delay")
                        }
                    }

                    // Mute
                    Toggle("Muted", isOn: $isMuted)
                        .onChange(of: isMuted) { applySetting() }

                    // Peak meter
                    peakMeterView
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                    ? Color(.windowBackgroundColor).opacity(0.95)
                    : Color(.windowBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1.5)
                )
        }
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    private var peakMeterView: some View {
        let key = device.id.uuidString
        let level = audioEngine.peakLevels[key] ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Level")
                Spacer()
                let db = level > 0.001 ? 20 * log10(Double(level)) : -60
                Text(String(format: "%.0f dB", db))
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.green, .green, .yellow, .orange, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: CGFloat(geo.size.width) * min(CGFloat(level), 1))
                        .animation(.easeOut(duration: 0.05), value: level)
                }
            }
            .frame(height: 6)
        }
    }

    private func applySetting() {
        let key = device.id.uuidString

        deviceSettings[key] = DeviceSettings(
            volume: Float(volume),
            delayMs: Float(delay),
            isMuted: isMuted,
            isSelected: isSelected
        )

        if isMuted {
            audioEngine.setDeviceSetting(key, isMuted: true)
        } else {
            audioEngine.setDeviceSetting(key, volume: Float(volume))
            audioEngine.setDeviceSetting(key, delayMs: Float(delay))
        }
    }
}
