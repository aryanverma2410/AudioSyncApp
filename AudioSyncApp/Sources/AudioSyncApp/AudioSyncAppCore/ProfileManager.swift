import Foundation

@MainActor
class AudioProfileManager: ObservableObject {
    @Published var profiles: [AudioProfile] = []
    @Published var selectedProfile: AudioProfile?

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AudioSyncApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("profiles.json")
        load()
    }

    func createProfile(named name: String) -> AudioProfile {
        let profile = AudioProfile(name: name)
        profiles.insert(profile, at: 0)
        save()
        selectedProfile = profile
        return profile
    }

    func selectProfile(_ profile: AudioProfile) {
        selectedProfile = profile
    }

    func deleteProfile(_ profile: AudioProfile) {
        profiles.removeAll { $0.id == profile.id }
        if selectedProfile?.id == profile.id {
            selectedProfile = profiles.first
        }
        save()
    }

    func renameProfile(_ profile: AudioProfile, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx].name = name
        if selectedProfile?.id == profile.id {
            selectedProfile = profiles[idx]
        }
        save()
    }

    func addDeviceSetting(_ profile: AudioProfile, deviceID: String, settings: DeviceSettings) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx].deviceSettings[deviceID] = settings
        save()
    }

    func applyProfile(_ profile: AudioProfile, to audioEngine: AudioEngine) {
        audioEngine.applyProfile(profile)
        selectedProfile = profile
    }

    func saveCurrentState() -> AudioProfile {
        // Build a profile from the current audio engine state
        let profile = AudioProfile(name: "Saved State \(Date().formatted(date: .abbreviated, time: .shortened))")
        profiles.insert(profile, at: 0)
        save()
        selectedProfile = profile
        return profile
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try encoder.encode(profiles)
            try data.write(to: fileURL)
        } catch {
            print("[ProfileManager] save error: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try decoder.decode([AudioProfile].self, from: data)
        } catch {
            print("[ProfileManager] load error: \(error)")
            profiles = []
        }
    }
}
