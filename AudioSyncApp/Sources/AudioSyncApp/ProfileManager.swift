import Foundation

// MARK: - Profile Manager

/// Manages audio profiles: CRUD, persistence to disk, and application to the engine.
@MainActor
final class ProfileManager: ObservableObject {
    @Published var profiles: [AudioProfile] = []
    @Published var selectedProfile: AudioProfile?

    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()
    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    // MARK: - Init

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("AudioSyncApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("profiles.json")
        load()
    }

    // MARK: - CRUD

    func createProfile(named name: String) -> AudioProfile {
        let profile = AudioProfile(name: name)
        profiles.insert(profile, at: 0)
        save()
        selectedProfile = profile
        return profile
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

    func updateDeviceSettings(_ profile: AudioProfile, deviceUID: String, settings: DeviceSettings) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx].deviceSettings[deviceUID] = settings
        save()
    }

    func selectProfile(_ profile: AudioProfile) {
        selectedProfile = profile
    }

    /// Saves the current device settings as a new profile.
    func saveAsProfile(named name: String, deviceSettings: [String: DeviceSettings]) -> AudioProfile {
        let profile = AudioProfile(name: name)
        profile.deviceSettings = deviceSettings
        profiles.insert(profile, at: 0)
        save()
        selectedProfile = profile
        return profile
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try encoder.encode(profiles)
            try data.write(to: fileURL, options: .atomicWrite)
        } catch {
            print("[ProfileManager] Save error: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try decoder.decode([AudioProfile].self, from: data)
            selectedProfile = profiles.first
        } catch {
            print("[ProfileManager] Load error: \(error)")
            profiles = []
        }
    }
}
