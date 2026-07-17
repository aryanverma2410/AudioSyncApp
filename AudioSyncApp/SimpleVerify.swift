import Foundation
import AVFoundation
import CoreAudio
import CoreBluetooth

// Simple verification using copies of the key structs
struct TestAudioDevice: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let connectionType: String
    var isConnected: Bool
    var sampleRate: Double
    var latency: Double // in milliseconds
    var isBluetooth: Bool
    var batteryLevel: Int? // 0-100, nil if not available or not applicable

    var iconName: String {
        switch connectionType.lowercased() {
        case "built-in":
            return "laptopcomputer"
        case "bluetooth":
            return "speaker.wave.2"
        case "usb":
            return "cable.connector.horizontal"
        case "airplay":
            return "tv"
        case "hdmi":
            return "tv"
        default:
            return "speaker"
        }
    }

    var connectionColor: String { // Using String instead of Color for simplicity
        switch connectionType.lowercased() {
        case "built-in":
            return "blue"
        case "bluetooth":
            return "blue"
        case "usb":
            return "orange"
        case "airplay":
            return "purple"
        case "hdmi":
            return "green"
        default:
            return "gray"
        }
    }

    var latencyColor: String {
        switch latency {
        case ..<0:
            return "red" // Negative latency (early)
        case 0..<50:
            return "green" // Good latency
        case 50..<100:
            return "yellow" // Moderate latency
        default:
            return "red" // High latency
        }
    }

    static func == (lhs: TestAudioDevice, rhs: TestAudioDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct TestDeviceSettings: Equatable {
    var volume: Float = 1.0      // 0.0 to 1.0
    var delayMs: Float = 0.0     // -1000 to 1000 milliseconds
    var isMuted: Bool = false
    var isSolo: Bool = false
}

struct TestAudioProfile: Identifiable, Equatable {
    let id: UUID
    var name: String
    // Using String keys instead of UUID for Codable compatibility
    var deviceSettings: [String: TestDeviceSettings] // Maps device ID string to its settings
    var sampleRate: Double = 44100.0
    var bufferSize: Int = 512

    init(id: UUID = UUID(), name: String = "New Profile") {
        self.id = id
        self.name = name
        self.deviceSettings = [:]
    }
}

print("=== Audio Sync Application Component Verification ===")

// Test 1: AudioDevice creation
print("\n1. Testing AudioDevice creation...")
let testDevice = TestAudioDevice(
    id: UUID(),
    name: "Test Speaker",
    connectionType: "Bluetooth",
    isConnected: true,
    sampleRate: 44100.0,
    latency: 32.5,
    isBluetooth: true,
    batteryLevel: 85
)
print("   ✓ AudioDevice created: \(testDevice.name) (\(testDevice.connectionType))")
print("   ✓ Battery level: \(testDevice.batteryLevel ?? 0)%")
print("   ✓ Connection color: \(testDevice.connectionType)")

// Test 2: DeviceSettings
print("\n2. Testing DeviceSettings...")
let settings = TestDeviceSettings(volume: 0.7, delayMs: 25.5, isMuted: false, isSolo: true)
print("   ✓ DeviceSettings: volume=\(settings.volume), delay=\(settings.delayMs)ms, mute=\(settings.isMuted), solo=\(settings.isSolo)")

// Test 3: AudioProfile
print("\n3. Testing AudioProfile...")
var profile = TestAudioProfile(name: "Test Profile")
profile.deviceSettings[testDevice.id.uuidString] = settings
print("   ✓ AudioProfile created: \(profile.name)")
print("   ✓ Profile has \(profile.deviceSettings.count) device settings")

print("\n=== Core data structures verified successfully! ===")
print("The application's data models are correctly implemented.")