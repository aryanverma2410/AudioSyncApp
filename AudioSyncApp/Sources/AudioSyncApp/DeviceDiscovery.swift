import Foundation
import CoreAudio
import Cocoa

// MARK: - Device Discovery

/// Discovers ALL audio output devices via CoreAudio, including built-in speakers,
/// Bluetooth, USB, AirPlay, HDMI, etc. Registers hot-plug listeners for real-time updates.
@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published var devices: [AudioOutputDevice] = []
    @Published var isScanning: Bool = false

    // Store the property address and listener proc as instance properties
    // so we can remove the listener in deinit (which can't access MainActor-isolated statics)
    private let listenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private let listenerProc: AudioObjectPropertyListenerProc = { _, _, _, userData in
        guard let userData = userData else { return OSStatus(noErr) }
        let manager = Unmanaged<DeviceDiscovery>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            manager.refreshCoreAudioDevices()
        }
        return OSStatus(noErr)
    }

    // Keep a reference to self for the C callback
    private var selfPointer: Unmanaged<DeviceDiscovery>?

    // MARK: - Init / Deinit

    init() {
        selfPointer = Unmanaged.passUnretained(self)
        setupDeviceListener()
        refreshDevices()
    }

    nonisolated deinit {
        // Remove the property listener before the object is freed to prevent
        // use-after-free in the CoreAudio callback.
        if let ptr = selfPointer {
            var addr = listenerAddress
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &addr,
                listenerProc,
                ptr.toOpaque()
            )
        }
    }

    // MARK: - Public

    func refreshDevices() {
        isScanning = true
        refreshCoreAudioDevices()
        isScanning = false
    }

    // MARK: - Hot-plug Listener

    private func setupDeviceListener() {
        guard let ptr = selfPointer else { return }
        var addr = listenerAddress
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            listenerProc,
            ptr.toOpaque()
        )
        if status != noErr {
            print("[DeviceDiscovery] Failed to add property listener: \(status)")
        }
    }

    // MARK: - CoreAudio Enumeration

    private func refreshCoreAudioDevices() {
        var deviceIDs: [AudioObjectID] = []
        getAudioDeviceIDs(&deviceIDs)

        let discovered = deviceIDs.compactMap { buildDevice(from: $0) }

        // Smart merge: preserve existing entries where possible to avoid UI flicker
        if devices.isEmpty {
            devices = discovered
        } else {
            var updated: [AudioOutputDevice] = []
            // Update existing and add new
            for newDev in discovered {
                if devices.contains(where: { $0.id == newDev.id }) {
                    // Preserve the device but update mutable fields
                    updated.append(newDev)
                } else {
                    updated.append(newDev)
                }
            }
            devices = updated
        }
    }

    private func getAudioDeviceIDs(_ ids: inout [AudioObjectID]) {
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
        guard status == noErr else {
            print("[DeviceDiscovery] GetPropertyDataSize failed: \(status)")
            return
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return }

        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &deviceIDs
        )
        guard status == noErr else {
            print("[DeviceDiscovery] GetPropertyData failed: \(status)")
            return
        }
        ids = deviceIDs
    }

    // MARK: - Build AudioOutputDevice

    private func buildDevice(from deviceID: AudioObjectID) -> AudioOutputDevice? {
        // Only include devices that have output streams
        guard hasOutputStreams(deviceID) else { return nil }

        let name = getDeviceName(deviceID)
        guard !name.isEmpty else { return nil }

        let uid = getDeviceUID(deviceID)
        let transport = getTransportType(deviceID)
        let sampleRate = getSampleRate(deviceID)
        let latency = getNominalLatency(deviceID)

        return AudioOutputDevice(
            id: deviceID,
            name: name,
            uid: uid,
            transportType: transport,
            sampleRate: sampleRate,
            nominalLatency: latency
        )
    }

    // MARK: - Output Stream Check

    /// Returns true if the device has at least one output stream.
    private func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return false }

        // Allocate buffer list and read
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        var localSize = size
        let readStatus = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &localSize, bufferList)
        guard readStatus == noErr else { return false }

        // Check if any buffer has non-zero channels
        let numBuffers = Int(bufferList.pointee.mNumberBuffers)
        guard numBuffers > 0 else { return false }

        // Access the variable-length buffer array with explicit pointer scope
        let totalChannels = withUnsafePointer(to: bufferList.pointee.mBuffers) { ptr in
            let buffers = UnsafeBufferPointer<AudioBuffer>(start: ptr, count: numBuffers)
            return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        return totalChannels > 0
    }

    // MARK: - Property Readers

    private func getDeviceName(_ deviceID: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // kAudioObjectPropertyName returns a CFString
        var cfString: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfString else { return "" }
        return cfString as String
    }

    private func getDeviceUID(_ deviceID: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // kAudioDevicePropertyDeviceUID returns a CFString
        var cfString: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfString else { return UUID().uuidString }
        return cfString as String
    }

    private func getTransportType(_ deviceID: AudioObjectID) -> AudioOutputDevice.TransportType {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size == MemoryLayout<UInt32>.size
        else { return .unknown }

        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr.baseAddress!)
        }
        guard status == noErr else { return .unknown }

        let rawValue = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt32.self)
        }

        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothLE
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeHDMI:
            return .hdmi
        default:
            return .unknown
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
        else { return 44100.0 }

        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr.baseAddress!)
        }
        guard status == noErr else { return 44100.0 }

        return data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: Float64.self)
        }
    }

    private func getNominalLatency(_ deviceID: AudioObjectID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyLatency,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size == MemoryLayout<UInt32>.size
        else { return 0 }

        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr.baseAddress!)
        }
        guard status == noErr else { return 0 }

        let frames = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: UInt32.self)
        }

        let sr = getSampleRate(deviceID)
        guard sr > 0 else { return 0 }
        return Double(frames) / sr * 1000.0  // Convert frames to milliseconds
    }
}
