import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var profileManager: AudioProfileManager

    @State private var showSettings = false
    @State private var showNewProfileAlert = false
    @State private var newProfileName = ""

    var body: some View {
        NavigationSplitView {
            // ── Sidebar ──
            List {
                Section("Profiles") {
                    ForEach(profileManager.profiles) { profile in
                        Button {
                            profileManager.selectProfile(profile)
                        } label: {
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .foregroundColor(.accentColor)
                                Text(profile.name)
                                Spacer()
                                if profileManager.selectedProfile?.id == profile.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showNewProfileAlert = true
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }
                }

                Section("Devices") {
                    if deviceManager.isScanning {
                        ProgressView("Scanning…")
                            .font(.caption)
                    } else {
                        ForEach(deviceManager.availableDevices) { dev in
                            HStack {
                                Image(systemName: dev.iconName)
                                    .foregroundColor(dev.connectionColor)
                                    .frame(width: 20)
                                Text(dev.name)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Int(dev.latency))ms")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .alert("New Profile", isPresented: $showNewProfileAlert) {
                TextField("Profile name", text: $newProfileName)
                    .onSubmit {
                        if !newProfileName.isEmpty {
                            _ = profileManager.createProfile(named: newProfileName)
                        }
                        newProfileName = ""
                    }
                Button("Create") {
                    if !newProfileName.isEmpty {
                        _ = profileManager.createProfile(named: newProfileName)
                    }
                    newProfileName = ""
                }
                Button("Cancel", role: .cancel) {
                    newProfileName = ""
                }
            } message: {
                Text("Create a new audio sync profile?")
            }

            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        audioEngine.load(url: nil)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title2)
                    }
                    .help("Play (uses generated tone)")
                    .disabled(!audioEngine.isInitialized)
                }

                ToolbarItem(placement: .navigation) {
                    Button {
                        if audioEngine.isPlaying {
                            audioEngine.pause()
                        } else {
                            audioEngine.start()
                        }
                    } label: {
                        Image(systemName: audioEngine.isPlaying
                            ? "pause.circle.fill"
                            : "play.circle.fill")
                        .font(.title2)
                    }
                    .help(audioEngine.isPlaying ? "Pause" : "Play")
                    .disabled(!audioEngine.isInitialized)
                }

                ToolbarItem(placement: .navigation) {
                    Button {
                        audioEngine.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .help("Stop")
                    .disabled(!audioEngine.isPlaying)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help("Settings")
                }
            }

            .sheet(isPresented: $showSettings) {
                AppSettingsView()
                    .environmentObject(audioEngine)
                    .environmentObject(deviceManager)
                    .environmentObject(profileManager)
                    .frame(width: 500, height: 420)
            }
        } detail: {
            if let profile = profileManager.selectedProfile {
                ProfileView(profile: profile)
                    .environmentObject(audioEngine)
                    .environmentObject(deviceManager)
                    .environmentObject(profileManager)
            } else {
                placeholderView
            }
        }
    }

    // ── Detail / placeholder ──

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Audio Sync")
                .font(.title)
                .fontWeight(.bold)

            Text("Select a profile or create a new one to start syncing audio to your devices.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Divider()

            VStack(spacing: 12) {
                Button {
                    showNewProfileAlert = true
                } label: {
                    Label("Create New Profile", systemImage: "plus.circle.fill")
                        .font(.title2)
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)

                Divider()
                    .frame(width: 200)

                Text("Tip: Install BlackHole for best results")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
