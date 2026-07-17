import Foundation
import CoreAudio
import Cocoa

@MainActor
class DeviceManager: ObservableObject {
    private static let devicePropertyListener: AudioObjectPropertyListenerProc = { _, _, _, userData in
        let manager = Unmanaged<DeviceManager>.fromOpaque(userData!).takeUnretainedValue()
        Task { @MainActor in
            manager.refreshCoreAudioDevices()
        }
        return OSStatus(noErr)
    }
    @Published var availableDevices: [AudioDevice] = []
    @Published var isScanning = false

    weak var delegate: DeviceManagerDelegate?

    init() {
        setupDeviceListener()
        refreshDevices()
    }

    // MARK: - Device Discovery

    func refreshDevices() {
        isScanning = true
        refreshCoreAudioDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isScanning = false
        }
    }

    // MARK: - Core Audio Discovery

    private func setupDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            DeviceManager.devicePropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func refreshCoreAudioDevices() {
        var devices: [AudioObjectID] = []
        getAudioDevices(&devices)

        let newDevices = devices.compactMap { createAudioDevice(from: $0) }

        // Preserve existing devices to avoid UI flashing
        if availableDevices.isEmpty {
            availableDevices = newDevices
        } else {
            var updated = availableDevices
            for newDev in newDevices {
                if let idx = updated.firstIndex(where: { $0.id == newDev.id }) {
                    updated[idx] = newDev
                } else {
                    updated.append(newDev)
                }
            }
            availableDevices = updated
        }

        delegate?.deviceManagerDidUpdateDevices(self)
    }

    private func getAudioDevices(_ devices: inout [AudioObjectID]) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size
        )
        guard status == noErr else { return }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &ids
        )
        guard status == noErr else { return }
        devices = ids
    }

    private func createAudioDevice(from deviceID: AudioObjectID) -> AudioDevice? {
        let name = getAudioDeviceName(deviceID)
        guard !name.isEmpty else { return nil }

        let uid = getDeviceUID(deviceID)
        let id = UUID(uuidString: uid) ?? UUID()

        let transport = getTransportType(deviceID)
        let (connectionType, _) = connectionType(for: transport)

        let sampleRate = getSampleRate(deviceID)
        let latency: Double
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            latency = 20
        case kAudioDeviceTransportTypeAirPlay:
            latency = 100
        default:
            latency = 5
        }

        return AudioDevice(
            id: id,
            name: name,
            connectionType: connectionType,
            isConnected: true,
            sampleRate: sampleRate,
            latency: latency
        )
    }

    // MARK: - Core Audio Property Helpers

    private func getAudioDeviceName(_ deviceID: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0
        else { return "" }

        var data = Data(count: Int(size))
        guard data.withUnsafeMutableBytes { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr.baseAddress!)
        } == noErr else { return "" }

        var name = String(decoding: data, as: UTF8.self)
        if let nullLoc = name.firstIndex(of: "\0") {
            name = String(name[..<nullLoc])
        }
        return name
    }

    private func getDeviceUID(_ deviceID: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0
        else { return UUID().uuidString }

        var data = Data(count: Int(size))
        guard data.withUnsafeMutableBytes { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr.baseAddress!)
        } == noErr else { return UUID().uuidString }

        let uid = String(decoding: data, as: UTF8.self)
        if let nullLoc = uid.firstIndex(of: "\0") {
            return String(uid[..<nullLoc])
        }
        return uid
    }

    private func getTransportType(_ deviceID: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size == MemoryLayout<UInt32>.size
        else { return 0 }

        var data = Data(count: Int(size))
        guard data.withUnsafeMutableBytes { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr.baseAddress!)
        } == noErr else { return 0 }

        return data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt32.self)
        }
    }

    private func getSampleRate(_ deviceID: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size == MemoryLayout<Float64>.size
        else { return 44100 }

        var data = Data(count: Int(size))
        guard data.withUnsafeMutableBytes { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr.baseAddress!)
        } == noErr else { return 44100 }

        return data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: Float64.self)
        }
    }

    private func connectionType(for transport: UInt32) -> (type: String, isBluetooth: Bool) {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth:
            return ("Bluetooth", true)
        case kAudioDeviceTransportTypeBluetoothLE:
            return ("Bluetooth LE", true)
        case kAudioDeviceTransportTypeBuiltIn:
            return ("Built-in", false)
        case kAudioDeviceTransportTypeUSB:
            return ("USB", false)
        case kAudioDeviceTransportTypeAirPlay:
            return ("AirPlay", false)
        case kAudioDeviceTransportTypeHDMI:
            return ("HDMI", false)
        case 0x40000000:
            return ("Loopback", false)
        default:
            return ("Unknown", false)
        }
    }
}
