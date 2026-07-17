import Foundation
import CoreAudio
import SwiftUI

// MARK: - Audio Device Model

struct AudioDevice: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let connectionType: String
    var isConnected: Bool
    var sampleRate: Double
    var latency: Double

    // Computed
    var isBluetooth: Bool {
        connectionType.hasPrefix("Bluetooth")
    }

    var iconName: String {
        switch connectionType.lowercased() {
        case "built-in", "internal":
            return "laptopcomputer"
        case "bluetooth":
            return "waveform.circle"
        case "usb":
            return "cable.connector.horizontal"
        case "airplay":
            return "airplay"
        case "hdmi":
            return "display"
        case "line-out", "optical":
            return "speaker.fill"
        default:
            return "speaker.fill"
        }
    }

    var connectionColor: Color {
        switch connectionType.lowercased() {
        case "built-in", "internal":
            return .blue
        case "bluetooth":
            return .cyan
        case "usb":
            return .orange
        case "airplay":
            return .purple
        case "hdmi", "line-out", "optical":
            return .green
        default:
            return .gray
        }
    }
}

// MARK: - Device Settings

struct DeviceSettings: Equatable, Codable {
    var volume: Float = 1.0
    var delayMs: Float = 0.0
    var isMuted: Bool = false
    var isSelected: Bool = false
}

// MARK: - Audio Profile

class AudioProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var deviceSettings: [String: DeviceSettings]
    var createdDate: Date

    init(id: UUID = UUID(), name: String = "New Profile") {
        self.id = id
        self.name = name
        self.deviceSettings = [:]
        self.createdDate = Date()
    }

    static func == (lhs: AudioProfile, rhs: AudioProfile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Delegate Protocols

protocol AudioEngineDelegate: AnyObject {
    func audioEngineDidChangeState(_ audioEngine: AudioEngine)
    func audioEngine(_ audioEngine: AudioEngine, didUpdatePeakLevel level: Float, forDevice deviceID: String)
    func audioEngine(_ audioEngine: AudioEngine, didUpdateCPUUsage usage: Double)
}

protocol DeviceManagerDelegate: AnyObject {
    func deviceManagerDidUpdateDevices(_ deviceManager: DeviceManager)
    func deviceManager(_ deviceManager: DeviceManager, didUpdateDevice device: AudioDevice)
}
