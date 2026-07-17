import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var profileManager: AudioProfileManager

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("defaultSampleRate") private var defaultSampleRate: Int = 44100
    @AppStorage("defaultBufferSize") private var defaultBufferSize: Int = 512

    var body: some View {
        Form {
            Section("Audio Engine") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(audioEngine.isInitialized ? "Initialized" : "Initializing…")
                        .foregroundColor(audioEngine.isInitialized ? .green : .orange)
                }

                HStack {
                    Text("Sample Rate")
                    Spacer()
                    Text("\(Int(audioEngine.sampleRate)) Hz")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Buffer Size")
                    Spacer()
                    Text("\(audioEngine.bufferSize)")
                        .foregroundColor(.secondary)
                }

                Button("Refresh Devices") {
                    deviceManager.refreshDevices()
                }
            }

            Section("Playback") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Toggle("Show in Menu Bar", isOn: $showInMenuBar)
            }

            Section("Audio Quality") {
                Picker("Sample Rate", selection: $defaultSampleRate) {
                    Text("44.1 kHz").tag(44100)
                    Text("48 kHz").tag(48000)
                    Text("96 kHz").tag(96000)
                }

                Picker("Buffer Size", selection: $defaultBufferSize) {
                    Text("128").tag(128)
                    Text("256").tag(256)
                    Text("512").tag(512)
                    Text("1024").tag(1024)
                    Text("2048").tag(2048)
                }
            }

            Section("BlackHole Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To capture system audio, install BlackHole:")
                        .font(.subheadline)

                    Text("1. Download BlackHole from")
                    Text("   blackhole.midi.md")
                        .foregroundStyle(Color.accentColor)

                    Text("2. Install the package")
                    Text("3. Set your music app's output to 'BlackHole'")
                    Text("4. Use Audio Sync to route to your Bluetooth devices")

                    Button("Open Download Page") {
                        if let url = URL(string: "https://blackhole.midi.md") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            Section("About") {
                Text("Audio Sync")
                    .font(.headline)
                Text("Version 1.0.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("An open-source alternative to Airfoil for macOS.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 420)
    }
}
