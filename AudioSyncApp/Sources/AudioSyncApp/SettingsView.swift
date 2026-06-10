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

            // TODO: Improve menu bar item state sync
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
                        }
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
