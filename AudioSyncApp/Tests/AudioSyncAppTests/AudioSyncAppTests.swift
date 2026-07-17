import XCTest
@testable import AudioSyncApp

final class AudioSyncAppTests: XCTestCase {
    func testAudioDeviceCreation() throws {
        // This is a simple test to verify the test target is set up correctly
        XCTAssertTrue(true)
    }

    func testAudioProfileInitialization() {
        let profile = AudioProfile(name: "Test Profile")
        XCTAssertEqual(profile.name, "Test Profile")
        XCTAssertEqual(profile.id.uuidString.count, 36) // UUID length
        XCTAssertTrue(profile.deviceSettings.isEmpty)
    }

    func testDeviceSettingsDefaultValues() {
        let settings = DeviceSettings()
        XCTAssertEqual(settings.volume, 1.0)
        XCTAssertEqual(settings.delayMs, 0.0)
        XCTAssertFalse(settings.isMuted)
        XCTAssertFalse(settings.isSelected)
    }

    @MainActor func testAudioEngineInitialization() {
        let audioEngine = AudioEngine()
        // Initially not initialized until we call initialize()
        XCTAssertFalse(audioEngine.isInitialized)
    }
}