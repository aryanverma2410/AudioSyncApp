import Foundation
import CoreAudio
import AudioToolbox
import Combine

/// Manages discovery of Bluetooth audio devices.
class DeviceManager: ObservableObject {
    static let shared = DeviceManager()
    @Published var bluetoothDevices: [AudioDevice] = []

    private init() {
        refresh()
        // Listen for device list changes.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMaster)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, deviceListChanged)
    }

    private let deviceListChanged: AudioObjectPropertyListenerBlock = { _, _ in
        DispatchQueue.main.async {
            DeviceManager.shared.refresh()
        }
    }

    /// Refreshes the list of Bluetooth devices.
    func refresh() {
        // If mock devices are set (e.g., in tests), use them.
        if let mock = DeviceManager.mockDevices {
            DispatchQueue.main.async { self.bluetoothDevices = mock }
            return
        }
        // Real implementation
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMaster)
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)

        var devices: [AudioDevice] = []

        for id in deviceIDs {
            // Get name
            var nameSize: UInt32 = 0
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMaster)
            AudioObjectGetPropertyDataSize(id, &nameAddress, 0, nil, &nameSize)
            var cfName: CFString = "" as CFString
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName)
            let name = cfName as String

            // Get transport type
            var transSize: UInt32 = 0
            var transAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioDevicePropertyElementMaster)
            AudioObjectGetPropertyDataSize(id, &transAddress, 0, nil, &transSize)
            var transportType: UInt32 = 0
            AudioObjectGetPropertyData(id, &transAddress, 0, nil, &transSize, &transportType)

            guard transportType == kAudioDeviceTransportTypeBluetooth else { continue }

            // Get UID
            var uidSize: UInt32 = 0
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMaster)
            AudioObjectGetPropertyDataSize(id, &uidAddress, 0, nil, &uidSize)
            var cfUID: CFString = "" as CFString
            AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &cfUID)
            let uid = cfUID as String

            devices.append(AudioDevice(id: id, name: name, uid: uid))
        }

        DispatchQueue.main.async {
            self.bluetoothDevices = devices
        }
    }

    // MARK: - Test helper
    /// Allows tests to inject a device list directly.
    func setBluetoothDevices(_ devices: [AudioDevice]) {
        DispatchQueue.main.async { self.bluetoothDevices = devices }
    }

    /// Static mock data for unit tests.
    static var mockDevices: [AudioDevice]? = nil

        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMaster)
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)

        var devices: [AudioDevice] = []

        for id in deviceIDs {
            // Get name
            var nameSize: UInt32 = 0
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMaster)
            AudioObjectGetPropertyDataSize(id, &nameAddress, 0, nil, &nameSize)
            var cfName: CFString = "" as CFString
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName)
            let name = cfName as String

            // Get transport type
            var transSize: UInt32 = 0
            var transAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMaster)
            AudioObjectGetPropertyDataSize(id, &transAddress, 0, nil, &transSize)
            var transportType: UInt32 = 0
            AudioObjectGetPropertyData(id, &transAddress, 0, nil, &transSize, &transportType)

            guard transportType == kAudioDeviceTransportTypeBluetooth else { continue }

            // Get UID
            var uidSize: UInt32 = 0
            var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMaster)
            AudioObjectGetPropertyDataSize(id, &uidAddress, 0, nil, &uidSize)
            var cfUID: CFString = "" as CFString
            AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &cfUID)
            let uid = cfUID as String

            devices.append(AudioDevice(id: id, name: name, uid: uid))
        }

        DispatchQueue.main.async {
            self.bluetoothDevices = devices
        }
    }
}
