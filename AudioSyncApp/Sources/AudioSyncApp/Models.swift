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
            // TODO: Update device list sorting logic
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
    var delayMs: Float = 0.0       // 0...maxDelayMs
    var volume: Float = 1.0        // 0...1
    var isMuted: Bool = false
    var isSubwoofer: Bool = false
    var crossoverHz: Float = 80     // low-pass cutoff for subwoofer mode

    static let defaultBluetooth = DeviceSettings(
        isEnabled: true,
        delayMs: 200,
        volume: 1.0,
        isMuted: false,
        isSubwoofer: false,
        crossoverHz: 80
    )

    static let maxDelayMs: Float = 1000
}

// MARK: - Reverb/Ambience Preset

enum ReverbPreset: Int, CaseIterable, Codable, Sendable {
    case none = 0, room = 1, hall = 2, stadium = 3, cathedral = 4

    var label: String {
        switch self {
        case .none: return "None"
        case .room: return "Room"
        case .hall: return "Hall"
        case .stadium: return "Stadium"
        case .cathedral: return "Cathedral"
        }
    }

    var icon: String {
        switch self {
        case .none: return "waveform"
        case .room: return "house"
        case .hall: return "music.note.house"
        case .stadium: return "sportscourt"
        case .cathedral: return "building.columns"
        }
    }
}

// MARK: - Room Profile

/// A saved snapshot of all device settings, order, and metronome BPM.
/// Used to quickly switch between room configurations (e.g., "Living Room", "Office").
struct RoomProfile: Codable, Equatable {
    var name: String
    var deviceSettings: [String: DeviceSettings]
    var deviceOrder: [String]
    var metronomeBPM: Int
    var timestamp: Date

    static func == (lhs: RoomProfile, rhs: RoomProfile) -> Bool {
        lhs.name == rhs.name
    }
}


