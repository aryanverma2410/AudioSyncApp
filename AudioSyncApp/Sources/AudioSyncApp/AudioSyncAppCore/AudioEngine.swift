import Foundation
import AVFoundation
import CoreAudio
import Accelerate

@MainActor
class AudioEngine: ObservableObject {
    // MARK: - Published Properties

    @Published var isInitialized = false
    @Published var isPlaying = false
    @Published var sampleRate: Double = 44100
    @Published var bufferSize: Int = 512
    @Published var cpuUsage: Double = 0.0
    @Published var peakLevels: [String: Float] = [:]

    // MARK: - Audio Components

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var mixerNode: AVAudioMixerNode?
    private var engineTimer: Timer?
    private var deviceSettings: [String: DeviceSettings] = [:]
    private var pendingURL: URL?

    weak var delegate: AudioEngineDelegate?

    // MARK: - Init

    init() {
        try? setupEngine()
    }

    // MARK: - Public

    func initialize() {
        do {
            try setupEngine()
            isInitialized = true
            delegate?.audioEngineDidChangeState(self)
        } catch {
            print("[AudioEngine] init error: \(error)")
            isInitialized = false
        }
    }

    func start() {
        guard isInitialized, let node = playerNode else { return }
        node.play()
        isPlaying = true
        startRenderLoop()
        delegate?.audioEngineDidChangeState(self)
    }

    func pause() {
        playerNode?.pause()
        stopRenderLoop()
        isPlaying = false
        delegate?.audioEngineDidChangeState(self)
    }

    func stop() {
        playerNode?.stop()
        stopRenderLoop()
        deviceSettings.removeAll()
        peakLevels.removeAll()
        isPlaying = false
        delegate?.audioEngineDidChangeState(self)
    }

    func load(url: URL?) {
        stop()
        pendingURL = url
        guard isInitialized else { return }
        if let url = url {
            loadAudioFile(url)
        } else {
            playSilentTone()
        }
        start()
    }

    // MARK: - Device Settings

    func setDeviceSetting(_ deviceID: String, volume: Float) {
        deviceSettings[deviceID, default: .init()].volume = volume
    }

    func setDeviceSetting(_ deviceID: String, delayMs: Float) {
        deviceSettings[deviceID, default: .init()].delayMs = delayMs
    }

    func setDeviceSetting(_ deviceID: String, isMuted: Bool) {
        deviceSettings[deviceID, default: .init()].isMuted = isMuted
    }

    func getDeviceSetting(for deviceID: String) -> DeviceSettings {
        deviceSettings[deviceID] ?? DeviceSettings()
    }

    func applyProfile(_ profile: AudioProfile) {
        deviceSettings = profile.deviceSettings
    }

    // MARK: - Private

    private func setupEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine

        let player = AVAudioPlayerNode()
        playerNode = player
        engine.attach(player)

        let mixer = AVAudioMixerNode()
        mixerNode = mixer
        engine.attach(mixer)

        engine.connect(player, to: mixer, format: nil)
        engine.connect(mixer, to: engine.outputNode, format: nil)

        try engine.start()

        // Install tap for level metering
        let format = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, _ in
            self?.processTap(buffer)
        }

        sampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
    }

    // MARK: - Audio Scheduling

    private func loadAudioFile(_ url: URL) {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            try audioFile.read(into: buffer)
            playerNode?.stop()
            playerNode?.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        } catch {
            print("[AudioEngine] load error: \(error)")
            playSilentTone()
        }
    }

    private func playSilentTone() {
        guard let node = playerNode else { return }

        let rate: Double = 44100
        let duration: Double = 0.3
        let frames = UInt32(rate * duration)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames

        let freq: Double = 660.0
        let amp: Float = 0.12

        for ch in 0..<2 {
            guard let data = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frames) {
                let t = Double(i) / rate
                let envelope = sin(t / duration * .pi)
                let sine = sin(2.0 * .pi * freq * t)
                data[i] = amp * Float(envelope) * Float(sine)
            }
        }

        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    // MARK: - Render Loop

    private func startRenderLoop() {
        stopRenderLoop()
        engineTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.renderUpdate()
            }
        }
    }

    private func stopRenderLoop() {
        engineTimer?.invalidate()
        engineTimer = nil
    }

    private func renderUpdate() {
        let start = mach_absolute_time()
        _ = sin(Double(start % 500))
        let elapsed = Double(mach_absolute_time() - start) * 1e-9
        cpuUsage = min(elapsed * 1000, 100)
    }

    // MARK: - Tap / Metering

    private func processTap(_ buffer: AVAudioPCMBuffer) {
        guard let chData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }

        var peak: Float = 0
        let frames = UInt32(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            var maxValue: Float = 0
            vDSP_maxv(chData[ch], 1, &maxValue, vDSP_Length(frames))
            peak = max(peak, maxValue)
        }

        for (id, settings) in deviceSettings {
            let level = isPlaying && !settings.isMuted
                ? peak * Float(settings.volume)
                : 0
            peakLevels[id] = level
        }

        delegate?.audioEngineDidChangeState(self)
    }
}
