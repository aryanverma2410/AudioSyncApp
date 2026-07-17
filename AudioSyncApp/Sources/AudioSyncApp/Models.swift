import Foundation
import SwiftUI

// MARK: - Audio Output Device

/// Represents a physical audio output device discovered via CoreAudio.
struct AudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: UInt32          // CoreAudio device ID
    let name: String
    let uid: String         // Stable device UID
    let transportType: TransportType
    var sampleRate: Double
    var nominalLatency: Double  // milliseconds

    // MARK: - Transport Type

    enum TransportType: String, CaseIterable, Codable {
        case builtIn = "Built-in"
        case bluetooth = "Bluetooth"
        case bluetoothLE = "Bluetooth LE"
        case usb = "USB"
        case airPlay = "AirPlay"
        case hdmi = "HDMI"
        case unknown = "Unknown"

        var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }

        var iconName: String {
            switch self {
            case .builtIn: return "laptopcomputer"
            case .bluetooth, .bluetoothLE: return "hifispeaker.and.signal"
            case .usb: return "cable.connector.horizontal"
            case .airPlay: return "airplay"
            case .hdmi: return "display"
            default: return "speaker.wave.2"
            }
        }

        var color: Color {
            switch self {
            case .builtIn: return .blue
            case .bluetooth, .bluetoothLE: return .cyan
            case .usb: return .orange
            case .airPlay: return .purple
            case .hdmi: return .green
            default: return .gray
            }
        }
    }

    // MARK: - Equatable (by CoreAudio device ID)

    static func == (lhs: AudioOutputDevice, rhs: AudioOutputDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Per-Device Settings

/// Per-device settings the user controls.
struct DeviceSettings: Equatable, Codable {
    var isEnabled: Bool = true
    var delayMs: Float = 0.0       // 0...2000 ms
    var volume: Float = 1.0        // 0...1
    var isMuted: Bool = false

    static let defaultBluetooth = DeviceSettings(
        isEnabled: true,
        delayMs: 200,   // Bluetooth typical latency compensation
        volume: 1.0,
        isMuted: false
    )
}

// MARK: - Audio Profile

/// Saved profile of device settings for a particular device combination.
class AudioProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var deviceSettings: [String: DeviceSettings]  // keyed by device UID
    var createdDate: Date

    init(id: UUID = UUID(), name: String = "New Profile") {
        self.id = id
        self.name = name
        self.deviceSettings = [:]
        self.createdDate = Date()
    }

    // Backward-compatible decoding: old profiles.json may lack 'createdDate'
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        deviceSettings = try container.decodeIfPresent([String: DeviceSettings].self, forKey: .deviceSettings) ?? [:]
        createdDate = try container.decodeIfPresent(Date.self, forKey: .createdDate) ?? Date.distantPast
    }

    static func == (lhs: AudioProfile, rhs: AudioProfile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
