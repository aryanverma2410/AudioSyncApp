import Foundation
import SwiftUI
import CoreAudio
import AudioToolbox

// MARK: - Shared CoreAudio Helpers

extension AudioObjectID {
    /// Read device display name from CoreAudio.
    var caDisplayName: String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfString else { return "" }
        return cfString as String
    }

    /// Check if device has at least one output stream.
    var caHasOutputStreams: Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        var localSize = size
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &localSize, bufferList) == noErr else { return false }

        let numBuffers = Int(bufferList.pointee.mNumberBuffers)
        guard numBuffers > 0 else { return false }

        let totalChannels = withUnsafePointer(to: bufferList.pointee.mBuffers) { ptr in
            let buffers = UnsafeBufferPointer<AudioBuffer>(start: ptr, count: numBuffers)
            return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        return totalChannels > 0
    }
}

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

    // Memberwise init (needed because defining init(from:) suppresses synthesis)
    init(isEnabled: Bool = true, delayMs: Float = 0.0, volume: Float = 1.0,
         isMuted: Bool = false, isSubwoofer: Bool = false, crossoverHz: Float = 80) {
        self.isEnabled = isEnabled
        self.delayMs = delayMs
        self.volume = volume
        self.isMuted = isMuted
        self.isSubwoofer = isSubwoofer
        self.crossoverHz = crossoverHz
    }

    // Backward-compatible decoding: old settings.json without isSubwoofer/crossoverHz
    // gets safe defaults instead of crashing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        delayMs = try c.decodeIfPresent(Float.self, forKey: .delayMs) ?? 0.0
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSubwoofer = try c.decodeIfPresent(Bool.self, forKey: .isSubwoofer) ?? false
        crossoverHz = try c.decodeIfPresent(Float.self, forKey: .crossoverHz) ?? 80
    }
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


