import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("defaultBluetoothDelay") private var defaultBluetoothDelay: Int = 200
    @AppStorage("autoStartCapture") private var autoStartCapture = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            audioTab
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }

            profilesTab
                .tabItem {
                    Label("Profiles", systemImage: "square.grid.2x2")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 380)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {  // DLog: Update toolbar layout constraints
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Toggle("Show in Menu Bar", isOn: $showInMenuBar)
            // TODO: Tweak ring buffer size constant
                Toggle("Auto-start audio capture", isOn: $autoStartCapture)
            }

            Section("Permissions") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Recording")
                            .font(.subheadline)
                        Text("Required to capture system audio via ScreenCaptureKit")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }  // DLog: Improve device discovery error handling
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let error = appState.systemCapturer.captureError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        Form {
            Section("Engine Status") {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.outputEngine.isRunning ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text(appState.outputEngine.isRunning ? "Running" : "Stopped")
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text("Active Devices")
                    Spacer()
                    Text("\(appState.outputEngine.activeDeviceCount)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("CPU Usage")
                    Spacer()
                    Text(String(format: "%.1f%%", appState.outputEngine.cpuUsage))
                        .foregroundColor(.secondary)
                }
            }

            Section("Default Values") {
                Picker("Bluetooth Delay", selection: $defaultBluetoothDelay) {
                    Text("0 ms").tag(0)
                    Text("100 ms").tag(100)
                    Text("150 ms").tag(150)
                    Text("200 ms").tag(200)
                    Text("300 ms").tag(300)
                    Text("500 ms").tag(500)
                }

                HStack {
                    Text("Engine Format")
                    Spacer()
                    Text("48 kHz / Stereo / Float32")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }

            Section("Device Discovery") {
                HStack {
                    Text("Detected Devices")
                    Spacer()
                    Text("\(appState.deviceDiscovery.devices.count)")
                        .foregroundColor(.secondary)
                }

                Button("Refresh Devices Now") {
                    appState.deviceDiscovery.refreshDevices()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Profiles Tab

    @State private var newProfileName = ""

    private var profilesTab: some View {
        Form {
            Section("Room Profiles") {
                Text("Save and restore speaker configurations for different rooms or setups. Use ⌘1–5 to quickly switch between the first 5 profiles.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if appState.profiles.isEmpty {
                    Text("No profiles saved yet")
                        .italic()
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.profiles.keys.sorted(), id: \.self) { name in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(name)
                                        .fontWeight(.medium)
                                    if appState.activeProfileName == name {
                                        Text("Active")
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.green.opacity(0.1))
                                            .cornerRadius(3)
                                    }
                                }
                                if let profile = appState.profiles[name] {
                                    Text("\(profile.deviceSettings.count) devices • \(profile.metronomeBPM) BPM • \(profile.timestamp, style: .relative)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                appState.loadProfile(name: name)
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Load this profile")

                            Button(role: .destructive) {
                                appState.deleteProfile(name: name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Delete this profile")
                        }
                    }
                }
            }

            Section("Create Profile") {
                HStack {
                    TextField("Profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Current") {
                        guard !newProfileName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        appState.saveProfile(name: newProfileName.trimmingCharacters(in: .whitespaces))
                        newProfileName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("AudioSync")
                .font(.title)
                .fontWeight(.bold)

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("An open-source Airfoil alternative for macOS.\nRoutes all system audio to multiple output devices\nwith per-speaker delay control.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Divider()
                .frame(width: 200)

            VStack(spacing: 8) {
                Text("Built with:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    techBadge("ScreenCaptureKit", icon: "capture.viewfinder")
                    techBadge("AVAudioEngine", icon: "waveform")
                    techBadge("CoreAudio", icon: "hifispeaker")
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func techBadge(_ name: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
            Text(name)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(width: 80)
    }
}
