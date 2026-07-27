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

// MARK: - Speaker Role

enum SpeakerRole: String, CaseIterable, Codable {
    case both = "L+R"
    case left = "Left"
    case center = "Center"
    case right = "Right"

    var iconName: String {
        switch self {
        case .both: return "waveform"
        case .left: return "speaker.wave.1"
        case .center: return "speaker"
        case .right: return "speaker.wave.1"
        }
    }
}

// MARK: - Per-Device Settings

/// Per-device settings the user controls.
struct DeviceSettings: Equatable, Codable {
    var isEnabled: Bool = true
    var delayMs: Float = 0.0       // 0...maxDelayMs
    var volume: Float = 1.0        // 0...1
    var isMuted: Bool = false
    var role: SpeakerRole = .both
    var bass: Float = 0.0          // -1...1 (negative = cut, positive = boost)
    var treble: Float = 0.0        // -1...1
    var mid: Float = 0.0           // -1...1

    static let defaultBluetooth = DeviceSettings(
        isEnabled: true,
        delayMs: 200,
        volume: 1.0,
        isMuted: false
    )

    static let maxDelayMs: Float = 1000
}

// MARK: - Device Habit (Learning)

/// Tracks a single device's volume and delay habits via exponential moving average (EMA).
/// Lightweight: ~24 bytes per device. Learns what the user *actually prefers* over time,
/// then uses that to seed auto-sync and restore settings on reconnect.
///
/// EMA math: `newValue = α × observed + (1 - α) × oldValue`
/// α = 0.2 gives ~5 observations to converge, smooth enough to ignore one-off tweaks.
struct DeviceHabit: Codable, Equatable {
    var volumeEMA: Float          // 0...1, learned preferred volume
    var delayEMA: Float           // 0...maxDelayMs, learned preferred delay
    var observationCount: Int     // how many data points we've seen
    var lastObserved: Date?       // when the user last adjusted this device

    /// Exponential moving average smoothing factor (0.2 = slow learner, steady)
    static let alpha: Float = 0.2

    /// Minimum observations before the EMA is considered "confident"
    static let confidentThreshold: Int = 3

    var isConfident: Bool { observationCount >= Self.confidentThreshold }

    init(volumeEMA: Float = 0, delayEMA: Float = 0, observationCount: Int = 0, lastObserved: Date? = nil) {
        self.volumeEMA = volumeEMA
        self.delayEMA = delayEMA
        self.observationCount = observationCount
        self.lastObserved = lastObserved
    }

    /// Record a new volume observation and update the EMA.
    mutating func observe(volume: Float) {
        if observationCount == 0 {
            volumeEMA = volume
        } else {
            volumeEMA = Self.alpha * volume + (1 - Self.alpha) * volumeEMA
        }
        observationCount += 1
        lastObserved = Date()
    }

    /// Record a new delay observation and update the EMA.
    mutating func observe(delay: Float) {
        if observationCount == 0 {
            delayEMA = delay
        } else {
            delayEMA = Self.alpha * delay + (1 - Self.alpha) * delayEMA
        }
        // Don't double-count — delay and volume often change together
        // Only update lastObserved if it hasn't been set this turn
        if lastObserved == nil { lastObserved = Date() }
    }

    /// Combined convenience: observe both volume and delay at once.
    mutating func observe(volume: Float, delay: Float) {
        observe(volume: volume)
        observe(delay: delay)
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


