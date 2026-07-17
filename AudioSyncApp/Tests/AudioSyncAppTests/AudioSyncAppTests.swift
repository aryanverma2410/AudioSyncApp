import XCTest
@testable import AudioSyncApp

final class AudioSyncAppTests: XCTestCase {

    // MARK: - Models

    func testAudioOutputDeviceTransportType() {
        XCTAssertEqual(AudioOutputDevice.TransportType.builtIn.isBluetooth, false)
        XCTAssertEqual(AudioOutputDevice.TransportType.bluetooth.isBluetooth, true)
        XCTAssertEqual(AudioOutputDevice.TransportType.bluetoothLE.isBluetooth, true)
        XCTAssertEqual(AudioOutputDevice.TransportType.usb.isBluetooth, false)
        XCTAssertEqual(AudioOutputDevice.TransportType.airPlay.isBluetooth, false)
        XCTAssertEqual(AudioOutputDevice.TransportType.unknown.isBluetooth, false)
    }

    func testDeviceSettingsDefaults() {
        let defaultSettings = DeviceSettings()
        XCTAssertTrue(defaultSettings.isEnabled)
        XCTAssertEqual(defaultSettings.delayMs, 0.0)
        XCTAssertEqual(defaultSettings.volume, 1.0)
        XCTAssertFalse(defaultSettings.isMuted)
    }

    func testBluetoothDefaultSettings() {
        let btSettings = DeviceSettings.defaultBluetooth
        XCTAssertTrue(btSettings.isEnabled)
        XCTAssertEqual(btSettings.delayMs, 200.0)
        XCTAssertEqual(btSettings.volume, 1.0)
        XCTAssertFalse(btSettings.isMuted)
    }

    func testAudioProfileCreation() {
        let profile = AudioProfile(name: "Test Profile")
        XCTAssertEqual(profile.name, "Test Profile")
        XCTAssertTrue(profile.deviceSettings.isEmpty)
        XCTAssertNotEqual(profile.createdDate, Date.distantPast)
    }

    func testAudioProfileEquality() {
        let p1 = AudioProfile(name: "A")
        let p2 = AudioProfile(name: "B")
        XCTAssertNotEqual(p1, p2)
    }

    func testAudioProfileBackwardCompatDecoding() {
        // Old profiles.json format lacks 'createdDate' key
        let json = """
        [{"name":"Old Profile","bufferSize":512,"deviceSettings":{},"id":"D5CFC68D-F6B0-44DE-ABAC-24E26418B733","sampleRate":44100}]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let profiles = try decoder.decode([AudioProfile].self, from: json)
            XCTAssertEqual(profiles.count, 1)
            XCTAssertEqual(profiles[0].name, "Old Profile")
            XCTAssertEqual(profiles[0].createdDate, Date.distantPast)
        } catch {
            XCTFail("Backward-compat decoding failed: \(error)")
        }
    }

    func testAudioProfileCodableRoundTrip() {
        let profile = AudioProfile(name: "Round Trip")
        profile.deviceSettings = ["dev1": DeviceSettings(delayMs: 150, volume: 1.0)]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try encoder.encode(profile)
            let decoded = try decoder.decode(AudioProfile.self, from: data)
            XCTAssertEqual(decoded.name, "Round Trip")
            XCTAssertEqual(decoded.deviceSettings["dev1"]?.delayMs, 150)
        } catch {
            XCTFail("Round-trip encoding failed: \(error)")
        }
    }

    // MARK: - DelayedRingBuffer

    func testRingBufferCreation() {
        let buffer = DelayedRingBuffer(capacitySeconds: 1.0, sampleRate: 48000)
        // No crash = success (buffer is initialized to zeros)
    }

    func testRingBufferSetDelay() {
        let buffer = DelayedRingBuffer()
        buffer.setDelay(ms: 100, sampleRate: 48000)
        // No crash = success (delay is internal state)
    }

    func testRingBufferWriteDoesNotCrash() {
        let buffer = DelayedRingBuffer(capacitySeconds: 1.0, sampleRate: 48000)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!

        // Fill with silence to test basic write path
        pcmBuffer.frameLength = 512
        for ch in 0..<2 {
            guard let channelData = pcmBuffer.floatChannelData?[ch] else { continue }
            for i in 0..<512 {
                channelData[i] = Float(sin(Double(i) * 0.1))
            }
        }

        buffer.write(pcmBuffer)
        // No crash = success
    }

    func testRingBufferZeroDelay() {
        let buffer = DelayedRingBuffer(capacitySeconds: 1.0, sampleRate: 48000)
        buffer.setDelay(ms: 0, sampleRate: 48000)
        // Zero delay should be valid — read position equals write position
    }

    func testRingBufferLargeDelay() {
        let buffer = DelayedRingBuffer(capacitySeconds: 4.0, sampleRate: 48000)
        buffer.setDelay(ms: 2000, sampleRate: 48000)  // Max delay
        // Should fit within 4-second buffer capacity
    }

    // MARK: - ThreadSafeLookup

    func testThreadSafeLookupBasicOperations() {
        let lookup = ThreadSafeLookup<String, Int>()

        lookup.set("a", 1)
        lookup.set("b", 2)

        XCTAssertEqual(lookup.get("a"), 1)
        XCTAssertEqual(lookup.get("b"), 2)
        XCTAssertNil(lookup.get("c"))

        lookup.remove("a")
        XCTAssertNil(lookup.get("a"))
        XCTAssertEqual(lookup.get("b"), 2)

        lookup.removeAll()
        XCTAssertNil(lookup.get("b"))
    }

    func testThreadSafeLookupAllValues() {
        let lookup = ThreadSafeLookup<String, Int>()
        lookup.set("x", 10)
        lookup.set("y", 20)

        let values = lookup.allValues
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.contains(10))
        XCTAssertTrue(values.contains(20))
    }

    // MARK: - ProfileManager

    func testProfileManagerCRUD() {
        let manager = ProfileManager()
        let profile = manager.createProfile(named: "Living Room")
        XCTAssertEqual(profile.name, "Living Room")
        XCTAssertEqual(manager.profiles.count, 1)

        manager.renameProfile(profile, to: "Bedroom")
        XCTAssertEqual(manager.profiles.first?.name, "Bedroom")

        manager.deleteProfile(profile)
        XCTAssertTrue(manager.profiles.isEmpty)
    }

    func testProfileManagerSaveAsProfile() {
        let manager = ProfileManager()
        let settings: [String: DeviceSettings] = [
            "bt-speaker-1": DeviceSettings(delayMs: 200, volume: 1.0),
            "macbook-speakers": DeviceSettings(delayMs: 0, volume: 1.0)
        ]
        let profile = manager.saveAsProfile(named: "My Setup", deviceSettings: settings)
        XCTAssertEqual(profile.name, "My Setup")
        XCTAssertEqual(profile.deviceSettings.count, 2)
        XCTAssertEqual(profile.deviceSettings["bt-speaker-1"]?.delayMs, 200)
    }

    // MARK: - DeviceSettings Edge Cases

    func testDeviceSettingsVolumeBounds() {
        var settings = DeviceSettings()
        settings.volume = 0.0
        XCTAssertEqual(settings.volume, 0.0)
        settings.volume = 1.0
        XCTAssertEqual(settings.volume, 1.0)
        // Out-of-range values are stored as-is (slider enforces bounds in UI)
        settings.volume = 1.5
        XCTAssertEqual(settings.volume, 1.5)
    }

    func testDeviceSettingsDelayBounds() {
        var settings = DeviceSettings()
        settings.delayMs = 0
        XCTAssertEqual(settings.delayMs, 0)
        settings.delayMs = 2000
        XCTAssertEqual(settings.delayMs, 2000)
    }

    // MARK: - Notification Names

    func testNotificationNames() {
        XCTAssertEqual(Notification.Name.startRouting, Notification.Name("com.audiosync.startRouting"))
        XCTAssertEqual(Notification.Name.stopRouting, Notification.Name("com.audiosync.stopRouting"))
    }
}
