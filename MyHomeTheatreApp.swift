import SwiftUI
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

// MARK: - Model ---------------------------------------------------------

/// Simple model representing an audio device.
public struct AudioDevice: Identifiable, Hashable {
    public let id: UInt32          // CoreAudio device ID
    public let name: String
    public let uid: String

    public init(id: UInt32, name: String, uid: String) {
        self.id = id
        self.name = name
        self.uid = uid
    }
}

// MARK: - Device Manager -----------------------------------------------

/// Manages discovery of Bluetooth audio devices.
class DeviceManager: ObservableObject {
    static let shared = DeviceManager()
    @Published var bluetoothDevices: [AudioDevice] = []

    private init() {
        refresh()
        // Listen for device list changes.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceListChanged)
    }

    private let deviceListChanged: AudioObjectPropertyListenerBlock = { _, _ in
        DispatchQueue.main.async {
            DeviceManager.shared.refresh()
        }
    }

    /// Refreshes the list of Bluetooth devices.
    func refresh() {
        // If mock data is set (tests), use it.
        if let mock = DeviceManager.mockDevices {
            DispatchQueue.main.async { self.bluetoothDevices = mock }
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMaster)
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil, &dataSize, &deviceIDs)

        var devices: [AudioDevice] = []

        for id in deviceIDs {
            // Get name
            var nameSize: UInt32 = 0
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMaster)
            AudioObjectGetPropertyDataSize(id, &nameAddress, 0, nil, &nameSize)
            var cfName: CFString = "" as CFString
            AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName)
            let name = cfName as String

            // Get transport type
            var transSize: UInt32 = 0
            var transAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMaster)
            AudioObjectGetPropertyDataSize(id, &transAddress, 0, nil, &transSize)
            var transportType: UInt32 = 0
            AudioObjectGetPropertyData(id, &transAddress, 0, nil, &transSize, &transportType)

            guard transportType == kAudioDeviceTransportTypeBluetooth else { continue }

            // Get UID
            var uidSize: UInt32 = 0
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
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
}

// MARK: - Audio Engine -----------------------------------------------

/// Singleton that owns the AVAudioEngine and per‑device chains.
final class AudioEngine {
    static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var delayNodes: [String: AVAudioUnitDelay] = [:]
    private var outputUnits: [String: AVAudioOutputNode] = [:]

    private init() {
        engine.attach(playerNode)
    }

    /// Sets up the engine for the given devices.
    func setup(with devices: [AudioDevice]) throws {
        // Detach any existing nodes
        for (_, node) in delayNodes { engine.detach(node) }
        for (_, node) in outputUnits { engine.detach(node) }
        delayNodes.removeAll()
        outputUnits.removeAll()

        for device in devices {
            let delay = AVAudioUnitDelay()
            delay.delayTime = 0
            engine.attach(delay)
            delayNodes[device.uid] = delay

            let outputUnit = try createOutputUnit(for: device)
            engine.attach(outputUnit)
            outputUnits[device.uid] = outputUnit

            engine.connect(playerNode, to: delay, format: nil)
            engine.connect(delay, to: outputUnit, format: nil)
        }

        try engine.start()
    }

    private func createOutputUnit(for device: AudioDevice) throws -> AVAudioOutputNode {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "AudioEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "HALOutput not found"])
        }
        var unit: AudioUnit = 0
        AudioComponentInstanceNew(comp, &unit)
        var devID = device.id
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        return AVAudioOutputNode(audioUnit: unit)
    }

    /// Loads an audio file and schedules it on the player node.
    func loadFile(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        playerNode.scheduleFile(file, at: nil, completionHandler: nil)
    }

    func play() { playerNode.play() }
    func stop() {
        playerNode.stop()
        engine.stop()
    }

    /// Sets the delay for a specific device.
    func setDelay(for uid: String, milliseconds: Float) {
        delayNodes[uid]?.delayTime = Double(milliseconds / 1000.0)
    }

    /// Helper for UI binding.
    func getDelay(for uid: String) -> Float {
        return Float(delayNodes[uid]?.delayTime ?? 0)
    }
}

// MARK: - SwiftUI UI -----------------------------------------------

struct ContentView: View {
    @StateObject private var deviceManager = DeviceManager.shared
    @State private var isPlaying = false

    var body: some View {
        VStack {
            HStack {
                Text("Bluetooth Speakers")
                    .font(.headline)
                Spacer()
                Button(action: syncDelays) {
                    Image(systemName: "arrow.2.circlepath")
                }
            }
            .padding(.horizontal)

            List(deviceManager.bluetoothDevices) { device in
                HStack {
                    Text(device.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(AudioEngine.shared.getDelay(for: device.uid)) },
                            set: { AudioEngine.shared.setDelay(for: device.uid, milliseconds: Float($0 * 1000)) }
                        ),
                        in: 0...1)
                        .frame(width: 150)
                    Text(String(format: "%.0f ms", AudioEngine.shared.getDelay(for: device.uid) * 1000))
                        .frame(width: 60, alignment: .trailing)
                }
            }
            .listStyle(PlainListStyle())

            HStack {
                Button(isPlaying ? "Stop" : "Play") {
                    if isPlaying {
                        AudioEngine.shared.stop()
                    } else {
                        guard let url = Bundle.main.url(forResource: "sample", withExtension: "mp3") else { return }
                        try? AudioEngine.shared.loadFile(url: url)
                        try? AudioEngine.shared.setup(with: deviceManager.bluetoothDevices)
                        AudioEngine.shared.play()
                    }
                    isPlaying.toggle()
                }
                .padding(.horizontal)
            }
        }
        .onChange(of: deviceManager.bluetoothDevices) { _ in
            if isPlaying {
                try? AudioEngine.shared.setup(with: deviceManager.bluetoothDevices)
            }
        }
    }

    /// Re‑builds the engine when devices change while playing.
    private func syncDelays() {
        if isPlaying {
            try? AudioEngine.shared.setup(with: deviceManager.bluetoothDevices)
        }
    }
}

// MARK: - App Entry Point -----------------------------------------------

@main
struct MyHomeTheatreApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
