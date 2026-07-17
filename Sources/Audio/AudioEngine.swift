import AVFoundation
import Foundation
import AudioToolbox

/// Singleton that owns the AVAudioEngine and per‑device chains.
final class AudioEngine {
    static let shared = AudioEngine()

    private let engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var delayNodes: [String: AVAudioUnitDelay] = [:]
    // Expose read access for UI
    func getDelay(for uid: String) -> Float {
        return Float(delayNodes[uid]?.delayTime ?? 0)
    }

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
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "AudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "HALOutput not found"])
        }
        var unit: AudioUnit = 0
        AudioComponentInstanceNew(comp, &unit)
        var devID = device.id
        AudioUnitSetProperty(unit,
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

    func play() {
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    /// Sets the delay for a specific device.
    func setDelay(for uid: String, milliseconds: Float) {
        delayNodes[uid]?.delayTime = Double(milliseconds / 1000.0)
    }
}
