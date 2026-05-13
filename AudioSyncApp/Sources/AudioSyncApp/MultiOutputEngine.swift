import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox
import Darwin

// MARK: - Atomic Float (for diagnostics)

/// Simple atomic Float for lock-free cross-thread reads of tap peak level.
final class AtomicFloat: @unchecked Sendable {
    private var _value: Float
    init(_ v: Float = 0) { _value = v }
    func store(_ v: Float) { _value = v }
    func load() -> Float { _value }
}

// MARK: - Thread-Safe Lookup

/// A lightweight thread-safe dictionary wrapper using os_unfair_lock.
/// Safe for audio-thread access (os_unfair_lock is a spinlock with no syscall in uncontended case).
final class ThreadSafeLookup<Key: Hashable, Value>: @unchecked Sendable {
    private var dict: [Key: Value] = [:]
    private var lock = os_unfair_lock_s()

    func get(_ key: Key) -> Value? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return dict[key]
    }

    func set(_ key: Key, _ value: Value) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        dict[key] = value
    }

    func remove(_ key: Key) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        dict.removeValue(forKey: key)
    }

    func removeAll() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        dict.removeAll()
    }

    /// Returns a snapshot of all values. Acquires lock briefly.
    var allValues: [Value] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(dict.values)
    }
}

// MARK: - Delayed Ring Buffer

/// A ring buffer that supports configurable read delay.
/// Lock-free single-producer single-consumer ring buffer with per-device delay.
/// Writer: IOProc capture callback (single producer).
/// Reader: HAL render callback (single consumer per device).
/// No locks — uses atomic positions with release/acquire barriers.
/// Safety margin prevents underruns on slow BT devices.
final class DelayedRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    private let frameCount: Int     // Total frames in ring (power-of-2 recommended)
    private let channels: Int = 2
    private let frameMask: Int      // frameCount - 1 for fast modulo (requires power-of-2)

    // Atomic positions — writer publishes writePos, reader publishes readPos
    private var _writePos: Int = 0  // Accessed atomically by writer
    private var _readPos: Int = 0   // Advanced by reader (independent of writer)
    private var _delayFrames: Int = 0

    // Safety margin: minimum distance between write and read (prevents underrun on BT)
    // BT codecs add 100-200ms latency; 4096 frames ≈ 85ms at 48kHz gives enough headroom.
    private let safetyFrames: Int = 4096

    private(set) var _writeCount: Int = 0
    private(set) var _readCount: Int = 0
    private(set) var _lastABLCount: Int = 0

    init(capacitySeconds: Double = 4.0, sampleRate: Double = 48000) {
        // Round up to next power of 2 for fast modulo
        let rawFrames = Int(capacitySeconds * sampleRate)
        var n = 1
        while n < rawFrames { n *= 2 }
        self.frameCount = n
        self.frameMask = n - 1
        self.buffer = .allocate(capacity: n * channels)
        self.buffer.initialize(repeating: 0, count: n * channels)
    }

    deinit { buffer.deallocate() }

    func setDelay(ms: Float, sampleRate: Double) {
        _delayFrames = Int(Double(ms) / 1000.0 * sampleRate)
    }

    /// Write stereo audio. Called from IOProc (single writer).
    func write(_ input: AVAudioPCMBuffer) {
        _writeCount += 1
        let frames = Int(input.frameLength)
        guard let left = input.floatChannelData?[0],
              let right = input.floatChannelData?[1] else { return }

        var wp = _writePos
        for i in 0..<frames {
            let idx = (wp & frameMask) * channels
            buffer[idx] = left[i]
            buffer[idx + 1] = right[i]
            wp += 1
        }
        // Release barrier then publish
        OSMemoryBarrier()
        _writePos = wp
    }

    /// Read stereo audio into AudioBufferList. Called from HAL render callback (single reader).
    /// Reader advances its own _readPos independently, but delay is enforced every read:
    /// if reader gets closer than (delayFrames + safetyFrames) behind writer, it's pushed back.
    func read(into ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        _readCount += 1
        _lastABLCount = abl.count

        OSMemoryBarrier()
        let wp = _writePos
        let delay = _delayFrames
        let totalBehind = delay + safetyFrames  // how far behind writer we must stay

        // First read ever: seed _readPos
        if _readPos == 0 && wp > 0 {
            _readPos = max(wp - totalBehind, 0)
        }

        // Enforce delay: if reader got too close to writer, push it back
        if wp - _readPos < totalBehind {
            _readPos = wp - totalBehind
        }

        var rp = _readPos

        // Catch-up: if reader fell too far behind (writer overtook the unread region),
        // snap read position forward to avoid reading stale/wrapped data.
        if wp - rp > frameCount {
            rp = wp - safetyFrames
        }

        // Underrun check: not enough data written yet
        if wp - rp < Int(frames) {
            DelayedRingBuffer.fillSilence(ioData, frames: frames)
            _readPos = max(rp, wp - totalBehind)
            return
        }

        if abl.count >= 2 {
            guard let leftData = abl[0].mData, let rightData = abl[1].mData else { return }
            let leftPtr = leftData.assumingMemoryBound(to: Float.self)
            let rightPtr = rightData.assumingMemoryBound(to: Float.self)

            for i in 0..<Int(frames) {
                let frameIdx = (rp + i) & frameMask
                let idx = frameIdx * channels
                leftPtr[i] = buffer[idx]
                rightPtr[i] = buffer[idx + 1]
            }
            abl[0].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
            abl[1].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        } else if abl.count == 1, let data = abl[0].mData {
            let ptr = data.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frames) {
                let frameIdx = (rp + i) & frameMask
                let idx = frameIdx * channels
                ptr[i * 2] = buffer[idx]
                ptr[i * 2 + 1] = buffer[idx + 1]
            }
            abl[0].mDataByteSize = frames * 2 * UInt32(MemoryLayout<Float>.size)
        }

        // Advance read position by frames consumed
        _readPos = rp + Int(frames)
    }

    /// Fill output with silence.
    static func fillSilence(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in abl {
            if let data = buf.mData {
                memset(data, 0, Int(buf.mDataByteSize))
            }
        }
    }

    /// Apply volume scaling to an AudioBufferList. Handles both interleaved and non-interleaved.
    static func applyVolume(_ vol: Float, to ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in abl {
            guard let data = buf.mData else { continue }
            let totalFloats = Int(frames) * Int(buf.mNumberChannels)
            let ptr = data.assumingMemoryBound(to: Float.self)
            for i in 0..<totalFloats {
                ptr[i] *= vol
            }
        }
    }
}

// File-scope storage for lookup tables (nonisolated, accessible from any context)
private let _bufferLookup = ThreadSafeLookup<String, DelayedRingBuffer>()
private let _volumeLookup = ThreadSafeLookup<String, Float>()

// MARK: - Multi-Output Engine

/// Routes system audio to multiple output devices with per-device delay and volume.
///
/// **Architecture:**
/// 1. A single `AVAudioPlayerNode` receives captured system audio buffers
/// 2. A tap on the main mixer captures the processed audio
/// 3. Each output device has a `DeviceOutput` struct with:
///    - A `DelayedRingBuffer` that introduces N ms of delay
///    - A HAL Output AudioUnit pointing to that specific device
///    - A render callback that reads from the delayed ring buffer
/// 4. When the tap fires, the audio is written to every device's ring buffer
/// 5. Each HAL unit's render callback reads from its (potentially delayed) buffer
///
/// This avoids the AVAudioEngine single-output-device limitation entirely.
@MainActor
final class MultiOutputEngine: ObservableObject {
    @Published var isRunning = false
    @Published var activeDeviceCount = 0
    @Published var cpuUsage: Double = 0

    private var deviceOutputs: [String: DeviceOutput] = [:]

    private let engineFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var cpuTimer: Timer?

    // MARK: - Device Output

    /// Represents one output device with its HAL output unit and delayed ring buffer.
    class DeviceOutput {
        let device: AudioOutputDevice
        let halUnit: AudioUnit
        let buffer: DelayedRingBuffer
        var volume: Float
        var isMuted: Bool
        let uidBox: UnsafeMutableRawPointer  // Retained NSString pointer for HAL render callback refCon

        init(device: AudioOutputDevice, halUnit: AudioUnit, buffer: DelayedRingBuffer, volume: Float, isMuted: Bool, uidBox: UnsafeMutableRawPointer) {
            self.device = device
            self.halUnit = halUnit
            self.buffer = buffer
            self.volume = volume
            self.isMuted = isMuted
            self.uidBox = uidBox
        }
    }

    // MARK: - Ring Buffer Lookup (for render callbacks)

    /// Thread-safe lookup tables so render callbacks can find their ring buffer and volume.
    /// Backed by file-scope nonisolated instances so they're accessible from any context.
    private static var bufferLookup: ThreadSafeLookup<String, DelayedRingBuffer> { _bufferLookup }
    private static var volumeLookup: ThreadSafeLookup<String, Float> { _volumeLookup }

    // MARK: - Configure

    func configure(devices: [(device: AudioOutputDevice, settings: DeviceSettings)]) throws {
        let wasRunning = isRunning
        if isRunning { stop() }
        teardownAll()

        // NOTE: We intentionally do NOT use AVAudioEngine for audio transport.
        // The previous pipeline (SCStream → sourceNode → engine tap → ringBuffer)
        // lost data because sourceNode.scheduleBuffer is one-shot and the engine
        // pulls continuously, leaving gaps of silence between SCStream deliveries.
        //
        // New pipeline: SCStream → distributeAudioDirect() → ringBuffer → HAL callback
        // AVAudioEngine is no longer part of the audio path.

        // Build per-device outputs
        for (device, settings) in devices {
            guard settings.isEnabled else {
                DLog("Skipping '\(device.name)' — disabled in settings")
                continue
            }
            do {
                try addDevice(device, settings: settings)
            } catch {
                DLog("Failed to add \(device.name): \(error)")
            }
        }

        DLog("Configured \(deviceOutputs.count) HAL output unit(s) out of \(devices.count) total devices")

        // Note: We no longer mute the default device HAL unit.
        // When using CoreAudio capture (BlackHole passthrough), the default output
        // goes to the virtual device, so our HAL units are the only way audio
        // reaches real speakers — no double-play.
        // When using SCStream, double-play on the default device is acceptable
        // since the user explicitly chose to route to that device.

        activeDeviceCount = deviceOutputs.count
        if wasRunning { start() }
    }

    // MARK: - Start / Stop

    /// Starts the HAL output units with diagnostic logging and throws on failure.
    func startSafely() throws {
        guard !isRunning else { return }

        DLog("Starting \(deviceOutputs.count) HAL output unit(s)...")
        for (uid, output) in deviceOutputs {
            DLog("  Starting HAL unit for '\(output.device.name)' (id=\(output.device.id))...")
            let status = AudioOutputUnitStart(output.halUnit)
            if status != noErr {
                DLog("  ERROR: AudioOutputUnitStart failed with status \(status) for '\(output.device.name)'")
                for (uid2, output2) in deviceOutputs where uid2 != uid {
                    AudioOutputUnitStop(output2.halUnit)
                }
                throw EngineError.halConfigFailed
            }
            DLog("  HAL unit started successfully for '\(output.device.name)'")
        }

        isRunning = true
        startCPUTimer()
        DLog("All \(deviceOutputs.count) HAL output units started successfully")
    }

    func start() {
        do {
            try startSafely()
        } catch {
            DLog("Start failed: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }

        for (_, output) in deviceOutputs {
            AudioOutputUnitStop(output.halUnit)
        }

        isRunning = false
        stopCPUTimer()
    }

    // MARK: - Direct Audio Distribution (from ScreenCaptureKit)

    /// Writes captured audio DIRECTLY to all device ring buffers.
    /// Called from SCStream's audio callback — bypasses AVAudioEngine entirely.
    nonisolated func distributeAudioDirect(_ buffer: AVAudioPCMBuffer) {
        // Diagnostic: measure peak level
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        if frames > 0, let left = buffer.floatChannelData?[0] {
            for i in 0..<min(frames, 512) {
                let v = abs(left[i])
                if v > peak { peak = v }
            }
        }
        _lastTapPeak.store(peak)
        _captureBox.count += 1

        for rb in _bufferLookup.allValues {
            rb.write(buffer)
        }
    }

    /// Counter for captured buffers (diagnostic, thread-safe via os_unfair_lock)
    private let _captureBox = CaptureCounterBox()

    /// Thread-safe box for counting captured buffers from nonisolated context
    private final class CaptureCounterBox: @unchecked Sendable {
        private var _count: Int = 0
        private var _lock = os_unfair_lock_s()
        var count: Int {
            get { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; return _count }
            set { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; _count = newValue }
        }
    }

    // MARK: - Test Tone (Diagnostic)

    /// Play a short 440Hz beep (0.3s) to a specific device's ring buffer.
    /// Bypasses the AVAudioEngine pipeline — writes directly to the HAL render buffer.
    func injectTestTone(for deviceUID: String) {
        guard let output = deviceOutputs[deviceUID] else {
            DLog("injectTestTone: no HAL unit for '\(deviceUID)'")
            return
        }

        // Temporarily start the HAL unit if engine isn't running
        let needsStart = !isRunning
        if needsStart {
            let status = AudioOutputUnitStart(output.halUnit)
            if status != noErr {
                DLog("injectTestTone: failed to start HAL unit (status \(status))")
                return
            }
        }

        Self.volumeLookup.set(deviceUID, output.volume)
        writeBeep(to: output.buffer, sampleRate: engineFormat.sampleRate)
        DLog("Test beep sent to '\(output.device.name)'")

        if needsStart {
            let halUnit = output.halUnit
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isRunning else { return }
                    AudioOutputUnitStop(halUnit)
                }
            }
        }
    }

    /// Play a short 440Hz beep to ALL device ring buffers.
    func injectTestToneAll() {
        let needsStart = !isRunning
        for (uid, output) in deviceOutputs {
            Self.volumeLookup.set(uid, output.volume)
            if needsStart {
                let status = AudioOutputUnitStart(output.halUnit)
                if status != noErr {
                    DLog("injectTestToneAll: failed to start HAL for '\(output.device.name)' (status \(status))")
                }
            }
            writeBeep(to: output.buffer, sampleRate: engineFormat.sampleRate)
        }
        DLog("Test beep sent to all \(deviceOutputs.count) device(s)")

        if needsStart {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isRunning else { return }
                    for (_, output) in self.deviceOutputs {
                        AudioOutputUnitStop(output.halUnit)
                    }
                }
            }
        }
    }

    /// Generate 0.3s of 440Hz sine wave and write it to a ring buffer.
    private func writeBeep(to buffer: DelayedRingBuffer, sampleRate: Double) {
        let frameCount: AVAudioFrameCount = AVAudioFrameCount(sampleRate * 0.3)  // 0.3 second beep
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        let freq = 440.0
        for frame in 0..<Int(frameCount) {
            // Fade in/out over 10ms to avoid clicks
            let fadeFrames = Int(sampleRate * 0.01)
            var envelope: Float = 1.0
            if frame < fadeFrames { envelope = Float(frame) / Float(fadeFrames) }
            else if frame > Int(frameCount) - fadeFrames { envelope = Float(Int(frameCount) - frame) / Float(fadeFrames) }

            let value = Float(sin(2.0 * .pi * freq * Double(frame) / sampleRate) * 0.5) * envelope
            pcmBuffer.floatChannelData?[0][frame] = value
            pcmBuffer.floatChannelData?[1][frame] = value
        }

        // Write enough copies to fill 1 second of ring buffer
        for _ in 0..<4 { buffer.write(pcmBuffer) }
    }

    /// Latest peak level from audio capture (for diagnostics)
    private let _lastTapPeak = AtomicFloat(0)

    // MARK: - Runtime Controls

    func updateDelay(for deviceUID: String, ms: Float) {
        guard let output = deviceOutputs[deviceUID] else { return }
        output.buffer.setDelay(ms: ms, sampleRate: engineFormat.sampleRate)
    }

    func updateVolume(for deviceUID: String, volume: Float) {
        guard deviceOutputs[deviceUID] != nil else { return }
        MultiOutputEngine.volumeLookup.set(deviceUID, volume)
        deviceOutputs[deviceUID]?.volume = volume
    }

    func updateMute(for deviceUID: String, isMuted: Bool) {
        guard let output = deviceOutputs[deviceUID] else { return }
        output.isMuted = isMuted
        MultiOutputEngine.volumeLookup.set(deviceUID, isMuted ? 0 : output.volume)
    }



    // MARK: - Add / Remove Device

    func addDevice(_ device: AudioOutputDevice, settings: DeviceSettings) throws {
        guard deviceOutputs[device.uid] == nil else { return }

        DLog("Adding device '\(device.name)' (transport=\(device.transportType.rawValue), id=\(device.id), sr=\(device.sampleRate))...")

        let ringBuffer = DelayedRingBuffer()
        ringBuffer.setDelay(ms: settings.delayMs, sampleRate: engineFormat.sampleRate)

        // Register in lookup tables BEFORE setting render callback
        MultiOutputEngine.bufferLookup.set(device.uid, ringBuffer)
        MultiOutputEngine.volumeLookup.set(device.uid, settings.isMuted ? 0 : settings.volume)

        // Store the device UID string in a heap box so the C callback can access it via refCon
        let uidBox = Unmanaged.passRetained(NSString(string: device.uid)).toOpaque()
        DLog("Created uidBox for '\(device.name)': refCon=\(uidBox), uid=\(device.uid)")

        // Create HAL unit: configure format + render callback BEFORE AudioUnitInitialize
        let halUnit = try createAndConfigureHALUnit(
            deviceID: device.id,
            refCon: uidBox
        )

        let output = DeviceOutput(
            device: device,
            halUnit: halUnit,
            buffer: ringBuffer,
            volume: settings.volume,
            isMuted: settings.isMuted,
            uidBox: uidBox
        )
        deviceOutputs[device.uid] = output
        activeDeviceCount = deviceOutputs.count
    }

    func removeDevice(_ deviceUID: String) {
        guard let output = deviceOutputs[deviceUID] else { return }
        AudioOutputUnitStop(output.halUnit)
        AudioUnitUninitialize(output.halUnit)
        AudioComponentInstanceDispose(output.halUnit)
        // Release the retained NSString that was passed to the HAL render callback refCon
        Unmanaged<NSString>.fromOpaque(output.uidBox).release()
        MultiOutputEngine.bufferLookup.remove(deviceUID)
        MultiOutputEngine.volumeLookup.remove(deviceUID)
        deviceOutputs.removeValue(forKey: deviceUID)
        activeDeviceCount = deviceOutputs.count
    }

    // MARK: - HAL Output Unit Creation

    private func createAndConfigureHALUnit(
        deviceID: UInt32,
        refCon: UnsafeMutableRawPointer
    ) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw EngineError.halComponentNotFound
        }
        var au: AudioUnit?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let audioUnit = au else {
            throw EngineError.halInstanceCreationFailed
        }

        // Enable output (bus 0, scope Output)
        var enable: UInt32 = 1
        guard AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Output, 0, &enable, 4) == noErr else {
            AudioComponentInstanceDispose(audioUnit); throw EngineError.halConfigFailed
        }

        // Disable input (bus 1, scope Input) — we don't need microphone
        var disable: UInt32 = 0
        guard AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Input, 1, &disable, 4) == noErr else {
            AudioComponentInstanceDispose(audioUnit); throw EngineError.halConfigFailed
        }

        // Point the HAL unit at the specific audio device
        var devID = deviceID
        guard AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                     kAudioUnitScope_Global, 0, &devID, 4) == noErr else {
            AudioComponentInstanceDispose(audioUnit); throw EngineError.halConfigFailed
        }

        // Set the input scope format to non-interleaved Float32 at our engine's sample rate.
        // This tells CoreAudio what format our render callback provides, and CoreAudio
        // inserts its own sample-rate converter / deinterleaver as needed for the device.
        // The previous crash was from the refCon parameter order bug (now fixed),
        // NOT from setting this format.
        var inputASBD = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let setFmtStatus = AudioUnitSetProperty(
            audioUnit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &inputASBD,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if setFmtStatus != noErr {
            DLog("WARNING: Failed to set input format for device \(deviceID) (status \(setFmtStatus)). Continuing with defaults.")
        } else {
            DLog("Set input format: non-interleaved Float32 48kHz for device \(deviceID)")
        }

        // Set the render callback BEFORE AudioUnitInitialize — this is critical.
        // CoreAudio validates the callback chain during initialization.
        var renderStruct = AURenderCallbackStruct(inputProc: Self.halRenderCallback, inputProcRefCon: refCon)
        guard AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input, 0,
                                     &renderStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else {
            AudioComponentInstanceDispose(audioUnit)
            throw EngineError.halConfigFailed
        }

        // Initialize AFTER all properties are set (including render callback)
        guard AudioUnitInitialize(audioUnit) == noErr else {
            AudioComponentInstanceDispose(audioUnit); throw EngineError.halConfigFailed
        }

        // Set device hardware volume to max — our app-side volume slider is the sole control.
        // Without this, the Notification Center volume multiplies with ours, confusing the user.
        Self.setDeviceVolumeMax(deviceID)

        // Verify the CurrentDevice actually stuck after initialization
        var verifyDevID: UInt32 = 0
        var verifySize = UInt32(MemoryLayout<UInt32>.size)
        let verifyStatus = AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &verifyDevID, &verifySize)
        if verifyStatus != noErr || verifyDevID != deviceID {
            DLog("ERROR: CurrentDevice verification failed! Expected=\(deviceID), Got=\(verifyDevID), status=\(verifyStatus)")
        } else {
            DLog("Verified: HAL unit bound to device \(deviceID)")
        }

        // Verify the input stream format
        var verifyASBD = AudioStreamBasicDescription()
        var verifyASBDSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let verifyFmtStatus = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                                     kAudioUnitScope_Input, 0, &verifyASBD, &verifyASBDSize)
        if verifyFmtStatus == noErr {
            DLog("Input format: sr=\(verifyASBD.mSampleRate), ch=\(verifyASBD.mChannelsPerFrame), flags=\(verifyASBD.mFormatFlags), bpf=\(verifyASBD.mBytesPerFrame)")
        }

        // Verify the output stream format (what the device actually expects)
        var verifyOutASBD = AudioStreamBasicDescription()
        var verifyOutASBDSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let verifyOutFmtStatus = AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                                        kAudioUnitScope_Output, 0, &verifyOutASBD, &verifyOutASBDSize)
        if verifyOutFmtStatus == noErr {
            DLog("Output format: sr=\(verifyOutASBD.mSampleRate), ch=\(verifyOutASBD.mChannelsPerFrame), flags=\(verifyOutASBD.mFormatFlags), bpf=\(verifyOutASBD.mBytesPerFrame)")
        }

        return audioUnit
    }

    // MARK: - Device Volume Override

    /// Set a HAL audio device's master volume to 1.0 (max).
    /// ponytail: Only sets channel 0/1 (stereo left/right). Some devices have weird channel layouts — we try and ignore failures.
    private static func setDeviceVolumeMax(_ deviceID: AudioObjectID) {
        for ch in [0, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: UInt32(ch))
            var vol: Float = 1.0
            let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &vol)
            if status != noErr {
                // Some devices don't support per-channel volume (e.g. aggregated) — non-fatal
                if ch == 0 { DLog("NOTE: device \(deviceID) ch\(ch) volume set failed (\(status)), may not support scalar volume") }
            }
        }
    }

    // MARK: - HAL Render Callback

    /// Global C-compatible render callback for all HAL output units.
    /// Uses the refCon (device UID) to look up the correct ring buffer and volume.
    /// Defined as a static method so it's a stable function pointer (not a closure context).
    private static let halRenderCallback: AURenderCallback = { (refCon, actionFlags, timeStamp, busNumber, inNumberFrames, ioData) -> OSStatus in
        // Recover the device UID from refCon (FIRST parameter in @convention(c) calling convention)
        let nsString = Unmanaged<NSString>.fromOpaque(refCon).takeUnretainedValue()
        let uid = nsString as String

        // Guard-unwrap ioData — if nil, just return noErr
        guard let ioData else {
            return noErr
        }

        // Look up ring buffer and volume — if either is missing, output silence
        guard let rb = _bufferLookup.get(uid) else {
            DelayedRingBuffer.fillSilence(ioData, frames: inNumberFrames)
            return noErr
        }

        let vol = _volumeLookup.get(uid) ?? 0

        if vol < 0.001 {
            DelayedRingBuffer.fillSilence(ioData, frames: inNumberFrames)
            return noErr
        }

        rb.read(into: ioData, frames: inNumberFrames)

        // Apply volume scaling if not 1.0
        if vol < 0.999 {
            DelayedRingBuffer.applyVolume(vol, to: ioData, frames: inNumberFrames)
        }

        return noErr
    }

    // MARK: - Teardown

    private func teardownAll() {
        for (uid, output) in deviceOutputs {
            AudioOutputUnitStop(output.halUnit)
            AudioUnitUninitialize(output.halUnit)
            AudioComponentInstanceDispose(output.halUnit)
            // Release the retained NSString that was passed to the HAL render callback refCon
            Unmanaged<NSString>.fromOpaque(output.uidBox).release()
            MultiOutputEngine.bufferLookup.remove(uid)
            MultiOutputEngine.volumeLookup.remove(uid)
        }
        deviceOutputs.removeAll()
        activeDeviceCount = 0
    }

    // MARK: - CPU

    private func startCPUTimer() {
        stopCPUTimer()
        cpuTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCPUUsage()
                self?.logDiagnostics()
            }
        }
    }

    private func logDiagnostics() {
        guard isRunning else { return }
        let tapPeak = _lastTapPeak.load()
        let bufCount = _captureBox.count
        DLog("diag: captureBufs=\(bufCount) capturePeak=\(String(format: "%.4f", tapPeak)) devices=\(deviceOutputs.count)")
        for (_, output) in deviceOutputs {
            let w = output.buffer._writeCount
            let r = output.buffer._readCount
            let vol = Self.volumeLookup.get(output.device.uid) ?? -1
            DLog("diag: '\(output.device.name)' writes=\(w) reads=\(r) vol=\(String(format: "%.2f", vol))")
        }
    }
    private func stopCPUTimer() { cpuTimer?.invalidate(); cpuTimer = nil; cpuUsage = 0 }

    /// Measure approximate CPU usage of the current process.
    /// Uses `ps` command to get real CPU% rather than a fake formula.
    private func updateCPUUsage() {
        guard isRunning else { cpuUsage = 0; return }

        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "%cpu=", "-o", "pcpu="]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            if let value = Double(output.components(separatedBy: .whitespaces).first ?? "0") {
                cpuUsage = min(value, 100.0)
            } else {
                cpuUsage = 0
            }
        } catch {
            // Fallback: estimate based on active device count
            cpuUsage = isRunning ? min(Double(activeDeviceCount) * 3.0 + 1.0, 100.0) : 0
        }
    }

    enum EngineError: LocalizedError {
        case halComponentNotFound, halInstanceCreationFailed, halConfigFailed
        var errorDescription: String? {
            switch self {
            case .halComponentNotFound: return "HAL audio component not found"
            case .halInstanceCreationFailed: return "Failed to create HAL audio unit"
            case .halConfigFailed: return "Failed to configure HAL audio unit"
            }
        }
    }
}
