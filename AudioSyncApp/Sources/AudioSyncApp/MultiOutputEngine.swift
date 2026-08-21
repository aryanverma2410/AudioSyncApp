import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox
import Darwin

// MARK: - Audio Constants

private let kEngineSampleRate: Double = 48000
private let kEngineChannels: UInt32 = 2
private let kSafetyFrames: Int = 8192        // ~170ms at 48kHz — BT codec headroom (was 4096)
private let kRingBufferPower: Int = 19       // 2^19 = 524288 frames ≈ 10.9s at 48kHz
private let kMaxDelayMs: Float = 5000        // Allow up to 5s delay for auto-compensation

// MARK: - Atomic Float (for diagnostics)

/// Simple atomic Float for lock-free cross-thread reads of tap peak level.
final class AtomicFloat: @unchecked Sendable {
    private var _value: Float
    private var _lock = os_unfair_lock_s()
    init(_ v: Float = 0) { _value = v }
    func store(_ v: Float) {
        os_unfair_lock_lock(&_lock)
        _value = v
        os_unfair_lock_unlock(&_lock)
    }
    func load() -> Float {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _value
    }
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

    /// Returns a snapshot of all keys. Acquires lock briefly.
    var allKeys: [Key] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(dict.keys)
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
    private let bufferSampleRate: Double  // Native sample rate of the target device

    // Atomic positions — writer publishes writePos, reader publishes readPos
    private var _writePos: Int = 0  // Accessed atomically by writer
    private var _readPos: Int = 0   // Advanced by reader (independent of writer)
    private var _delayFrames: Int = 0
    private var _resamplePhase: Double = 0  // Carried fractional position for linear resampling

    // Safety margin: minimum distance between write and read (prevents underrun on BT)
    // BT codecs add 100-200ms latency; kSafetyFrames ≈ 85ms at 48kHz gives enough headroom.
    private let safetyFrames: Int = kSafetyFrames

    private(set) var _writeCount: Int = 0
    private(set) var _readCount: Int = 0
    private(set) var _lastABLCount: Int = 0
    private(set) var underrunCount: Int = 0
    private(set) var lastDrift: Int = 0

    init(capacitySeconds: Double = 6.0, sampleRate: Double = kEngineSampleRate) {
        self.bufferSampleRate = sampleRate
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

    var frameCountValue: Int { frameCount }

    func setDelay(ms: Float) {
        let newDelayFrames = Int(Double(ms) / 1000.0 * bufferSampleRate)
        _delayFrames = newDelayFrames

        // Immediately resync read position to the new delay distance.
        // Without this, the ±1-sample drift correction takes thousands of
        // callbacks to converge — slider feels non-responsive.
        let wp = _writePos
        if wp > 0 {
            _readPos = max(wp - newDelayFrames - safetyFrames, 0)
        }
    }

    /// Current write position (for diagnostics / auto-delay measurement)
    var currentWritePos: Int { _writePos }
    /// Current read position (for diagnostics / auto-delay measurement)
    var currentReadPos: Int { _readPos }

    /// Write stereo audio. Called from IOProc (single writer).
    /// Resamples from the input buffer's sample rate to the ring buffer's native rate.
    func write(_ input: AVAudioPCMBuffer) {
        _writeCount += 1
        let inputFrames = Int(input.frameLength)
        guard let left = input.floatChannelData?[0],
              let right = input.floatChannelData?[1] else { return }

        let inputRate = input.format.sampleRate

        // Fast path: no resampling needed (rates match)
        if inputRate == bufferSampleRate || inputRate == 0 {
            var wp = _writePos
            for i in 0..<inputFrames {
                let idx = (wp & frameMask) * channels
                buffer[idx] = left[i]
                buffer[idx + 1] = right[i]
                wp += 1
            }
            OSMemoryBarrier()
            _writePos = wp
            return
        }

        // Resample from inputRate → bufferSampleRate using linear interpolation.
        // step = inputRate / bufferSampleRate (input frames consumed per output frame produced)
        let step = inputRate / bufferSampleRate
        var wp = _writePos
        var phase = _resamplePhase  // Carried across calls for continuity

        while true {
            let i0 = Int(phase)
            if i0 >= inputFrames { break }

            let frac = Float(phase - Double(i0))

            // Clamp edge indices to valid range
            let idx0 = max(0, min(i0, inputFrames - 1))
            let idx1 = max(0, min(i0 + 1, inputFrames - 1))

            let bufIdx = (wp & frameMask) * channels
            buffer[bufIdx] = left[idx0] * (1 - frac) + left[idx1] * frac
            buffer[bufIdx + 1] = right[idx0] * (1 - frac) + right[idx1] * frac
            wp += 1

            phase += step
        }

        // Carry fractional position for next call
        _resamplePhase = phase - Double(inputFrames)
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

        var rp = _readPos

        // Gradual drift correction: nudge read position by ±1 sample per callback.
        // Hard-snap (jumping 100+ samples) caused audible clicks on BT speakers.
        // Gradual correction eliminates discontinuity while still tracking drift.
        let currentDist = wp - rp
        lastDrift = currentDist - totalBehind
        if currentDist < totalBehind {
            rp += 1  // reader too close to writer — skip 1 sample to fall back
        } else if currentDist > totalBehind + Int(frames) * 2 {
            rp -= 1  // reader too far behind — repeat 1 sample to catch up
            if rp < 0 { rp = 0 }
        }

        // Catastrophic overrun: reader fell behind by more than the entire ring buffer.
        // Only here do we hard-snap to avoid reading stale/wrapped data.
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
private let _levelLookup = ThreadSafeLookup<String, Float>()  // VU meter: per-device peak level

// EQ coefficients: bass, treble, mid gain (-1...1) per device UID
private let _bassLookup = ThreadSafeLookup<String, Float>()
private let _trebleLookup = ThreadSafeLookup<String, Float>()
private let _midLookup = ThreadSafeLookup<String, Float>()
// Master volume multiplier (applied on top of individual volumes in render callback)
private let _masterVolume = AtomicFloat(1.0)

// MARK: - Audio Mode (global: normal, karaoke, vocal-boost)

enum AudioMode: Int, Sendable {
    case normal = 0
    case karaoke = 1
    case vocalBoost = 2
}

// Global audio mode — affects all devices
private let _audioMode = AtomicFloat(0)  // 0=normal, 1=karaoke, 2=vocalBoost

// CPU overload flag — set when CPU > 80%, cleared when it drops below 60%
private let _cpuOverloadFlag = AtomicFloat(0)

// Reverb settings (global, applied to per-device instances)
private let _reverbPresetRaw = AtomicFloat(0)

// Subwoofer crossover: per-device low-pass filter state
private let _subwooferLookup = ThreadSafeLookup<String, Bool>()
private let _crossoverHzLookup = ThreadSafeLookup<String, Float>()
// LPF state per device for subwoofer crossover (2nd-order Butterworth)
private final class CrossoverLPF: @unchecked Sendable {
    private var z1: Float = 0
    private var z2: Float = 0
    private var cutoffFreq: Float = 80
    private var sampleRate: Float = 48000

    func setCutoff(_ freq: Float, sampleRate: Float) {
        self.cutoffFreq = freq
        self.sampleRate = sampleRate
    }

    func process(_ sample: Float) -> Float {
        // 2nd-order Butterworth low-pass via biquad
        let w0 = 2 * Float.pi * cutoffFreq / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (Float(2) * 0.707) // Q = 0.707 for Butterworth
        let b0 = (1 - cosW0) / 2
        let b1 = 1 - cosW0
        let b2 = (1 - cosW0) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosW0
        let a2 = 1 - alpha
        let x = sample
        let y = b0 / a0 * x + b1 / a0 * z1 + b2 / a0 * z2 - a1 / a0 * (z1) - a2 / a0 * (z2)
        z2 = z1
        z1 = y
        return y
    }
}
private let _crossoverLPFLookup = ThreadSafeLookup<String, CrossoverLPF>()

// Per-device reverb instances (each HAL thread gets its own)
private let _reverbLookup = ThreadSafeLookup<String, Reverb>()

// Aggressive karaoke: extracts bass from center channel to preserve while removing vocals
private final class KaraokeFilter: @unchecked Sendable {
    private var _lpfZ: Float = 0
    private let _alpha: Float = 0.99  // ~100Hz cutoff at 48kHz — preserves bass/kick, cuts vocals

    @inline(__always)
    func process(_ center: Float) -> Float {
        _lpfZ = _alpha * _lpfZ + (1 - _alpha) * center
        return _lpfZ  // bass-only portion of center
    }
}
private let _karaokeBassLookup = ThreadSafeLookup<String, KaraokeFilter>()

// Simple feedback reverb — one delay line with dampened feedback.
// Far less CPU than Schroeder (1 delay vs 6), no crackling on BT.
final class Reverb: @unchecked Sendable {
    private var delayBuf: UnsafeMutablePointer<Float>
    private let delaySize: Int
    private var delayIdx: Int = 0
    // Second delay line for denser, fuller reverb (different length avoids comb-filter ringing)
    private var delayBuf2: UnsafeMutablePointer<Float>
    private let delaySize2: Int
    private var delayIdx2: Int = 0
    private var feedback: Float = 0
    private var dampened: Float = 0  // lowpassed feedback state
    private var dampened2: Float = 0
    var wetMix: Float = 0
    var isEnabled: Bool = false

    enum Preset: Int, Sendable {
        case none = 0, room = 1, hall = 2, stadium = 3, cathedral = 4
    }

    init() {
        // Primary: ~40ms delay at 48kHz
        delaySize = 2048  // power of 2 for fast modulo
        delayBuf = UnsafeMutablePointer<Float>.allocate(capacity: delaySize)
        delayBuf.initialize(repeating: 0, count: delaySize)
        // Secondary: ~59ms delay (prime ratio for dense, non-metallic reverb)
        delaySize2 = 2816  // ~59ms at 48kHz, power of 2? No — use mask approach
        delayBuf2 = UnsafeMutablePointer<Float>.allocate(capacity: delaySize2)
        delayBuf2.initialize(repeating: 0, count: delaySize2)
    }

    deinit { delayBuf.deallocate(); delayBuf2.deallocate() }

    func setPreset(_ preset: Preset) {
        switch preset {
        case .none:
            isEnabled = false
        case .room:
            isEnabled = true
            wetMix = 0.28
            feedback = 0.52
        case .hall:
            isEnabled = true
            wetMix = 0.38
            feedback = 0.62
        case .stadium:
            isEnabled = true
            wetMix = 0.50
            feedback = 0.70
        case .cathedral:
            isEnabled = true
            wetMix = 0.60
            feedback = 0.78
        }
    }

    /// Returns the wet (reverberated) signal only. Caller mixes dry + wet.
    @inline(__always)
    func processWet(_ sample: Float) -> Float {
        guard isEnabled else { return 0 }
        // Primary delay line
        let delayed = delayBuf[delayIdx]
        dampened = dampened * 0.5 + delayed * 0.5
        delayBuf[delayIdx] = sample + dampened * feedback
        delayIdx = (delayIdx + 1) & (delaySize - 1)
        // Secondary delay line (adds density — different length decorrelates reflections)
        let delayed2 = delayBuf2[delayIdx2]
        dampened2 = dampened2 * 0.6 + delayed2 * 0.4  // slightly different damping
        delayBuf2[delayIdx2] = sample + dampened2 * feedback
        delayIdx2 = (delayIdx2 + 1) % delaySize2  // modulo for non-power-of-2
        return (delayed + delayed2) * 0.5
    }

    /// Full process: returns dry + wet. Used for mono fallback path.
    @inline(__always)
    func process(_ sample: Float) -> Float {
        guard isEnabled else { return sample }
        return sample + processWet(sample) * wetMix
    }
}

// Per-device end-to-end latency (ms), updated in render callback
private let _latencyLookup = ThreadSafeLookup<String, Float>()
// Timestamp of last audio buffer capture (mach_absolute_time)
private final class AtomicUInt64: @unchecked Sendable {
    private var _value: UInt64 = 0
    private var _lock = os_unfair_lock_s()
    func store(_ v: UInt64) { os_unfair_lock_lock(&_lock); _value = v; os_unfair_lock_unlock(&_lock) }
    func load() -> UInt64 { os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }; return _value }
}
private let _captureTimestamp = AtomicUInt64()

// MARK: - Device Health Tracking
struct DeviceHealth: Sendable {
    var underrunCount: Int
    var avgDrift: Float
    var bufferFillPercent: Float
    var latencyMs: Float
    var isHealthy: Bool { underrunCount < 10 && abs(avgDrift) < 500 }
}

private let _underrunCountLookup = ThreadSafeLookup<String, Int>()
private let _driftLookup = ThreadSafeLookup<String, Float>()

// MARK: - Simple Biquad (1st-order shelf for bass/treble, peaking for mid)

/// Applies a simple one-pole low-shelf (bass), high-shelf (treble), or peaking (mid) filter.
/// Coefficient: -1 = max cut, 0 = flat, +1 = max boost (~±6dB range).
/// Uses a single-pole IIR per band — cheap and stable on the audio thread.
private final class SimpleEQ: @unchecked Sendable {
    private var _bassZ: Float = 0
    private var _trebleZ: Float = 0
    private var _midZ: Float = 0
    private let _alpha: Float = 0.995  // ~6Hz cutoff at 48kHz for shelf edges

    func process(_ sample: Float, bass: Float, treble: Float, mid: Float) -> Float {
        // Bass shelf: boost/cut low frequencies
        _bassZ = _alpha * _bassZ + (1 - _alpha) * sample
        let bassOut = sample + bass * 3.0 * (_bassZ - sample * 0.5)

        // Treble shelf: boost/cut high frequencies (via differencing)
        let hp = sample - _bassZ  // high-pass residue
        _trebleZ = _alpha * _trebleZ + (1 - _alpha) * hp
        let trebleOut = bassOut + treble * 3.0 * (_trebleZ - hp * 0.5)

        // Mid: peaking via bandpass (difference of low-pass and high-pass)
        let bp = _bassZ - _trebleZ
        _midZ = _alpha * _midZ + (1 - _alpha) * bp
        let midOut = trebleOut + mid * 2.5 * (_midZ - bp * 0.5)

        return midOut
    }
}

// Per-device EQ state (persistent across callbacks)
private let _eqLookup = ThreadSafeLookup<String, SimpleEQ>()

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
    private var cpuOverloadCount = 0

    private var deviceOutputs: [String: DeviceOutput] = [:]

    private let engineFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: kEngineSampleRate, channels: 2)!
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
        let sampleRate: Double  // Device's native sample rate (for delay calculations)

        init(device: AudioOutputDevice, halUnit: AudioUnit, buffer: DelayedRingBuffer, volume: Float, isMuted: Bool, uidBox: UnsafeMutableRawPointer) {
            self.device = device
            self.halUnit = halUnit
            self.buffer = buffer
            self.volume = volume
            self.isMuted = isMuted
            self.uidBox = uidBox
            self.sampleRate = device.sampleRate > 0 ? device.sampleRate : kEngineSampleRate
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
            var status: OSStatus = noErr
            var retries = 0
            repeat {
                status = AudioOutputUnitStart(output.halUnit)
                if status != noErr {
                    retries += 1
                    DLog("  HAL start attempt \(retries)/3 failed for '\(output.device.name)' (status=\(status)), retrying in 500ms...")
                    if retries < 3 {
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
            } while status != noErr && retries < 3

            if status != noErr {
                DLog("  ERROR: AudioOutputUnitStart failed after 3 retries for '\(output.device.name)'")
                for (uid2, output2) in deviceOutputs where uid2 != uid {
                    AudioOutputUnitStop(output2.halUnit)
                }
                throw EngineError.halConfigFailed
            }
            DLog("  HAL unit started successfully for '\(output.device.name)'\(retries > 0 ? " (after \(retries) retries)" : "")")
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
        _captureTimestamp.store(mach_absolute_time())
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

    /// Inject a calibration chirp (1000→2000Hz sweep, 60ms) into a specific device's ring buffer.
    /// Used by AcousticCalibrator to measure real speaker latency via mic.
    func injectCalibrationChirp(for deviceUID: String) {
        guard let output = deviceOutputs[deviceUID] else {
            DLog("injectCalibrationChirp: no HAL unit for '\(deviceUID)'")
            return
        }

        let needsStart = !isRunning
        if needsStart {
            let status = AudioOutputUnitStart(output.halUnit)
            if status != noErr {
                DLog("injectCalibrationChirp: failed to start HAL unit (status \(status))")
                return
            }
        }

        // Ensure volume is non-zero so chirp is audible
        Self.volumeLookup.set(deviceUID, max(output.volume, 0.5))

        let sampleRate = engineFormat.sampleRate
        let chirpDuration = 0.06  // 60ms
        let totalFrames = AVAudioFrameCount(sampleRate * chirpDuration)

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: totalFrames) else { return }
        pcmBuffer.frameLength = totalFrames

        let freqStart: Double = 1000.0
        let freqEnd: Double = 2000.0
        var phase: Float = 0

        for frame in 0..<Int(totalFrames) {
            let progress = Double(frame) / Double(totalFrames)
            let freq = freqStart + (freqEnd - freqStart) * progress
            phase += Float(2.0 * Double.pi * freq / sampleRate)
            let envelope = cosineEnvelope(frame: frame, totalFrames: Int(totalFrames), sampleRate: sampleRate)
            let value = Float(sin(Double(phase))) * envelope * 0.9
            pcmBuffer.floatChannelData?[0][frame] = value
            pcmBuffer.floatChannelData?[1][frame] = value
        }

        output.buffer.write(pcmBuffer)
        DLog("Calibration chirp injected into '\(output.device.name)'")

        if needsStart {
            let halUnit = output.halUnit
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
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

    private func writeBeep(to buffer: DelayedRingBuffer, sampleRate: Double) {
        let toneDuration = 0.08   // 80ms per tone
        let gapDuration = 0.04    // 40ms gap
        let totalDuration = toneDuration * 2 + gapDuration
        let totalFrames = AVAudioFrameCount(sampleRate * totalDuration)
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: totalFrames) else { return }
        pcmBuffer.frameLength = totalFrames
        
        let tone1End = Int(sampleRate * toneDuration)
        let gapEnd = Int(sampleRate * (toneDuration + gapDuration))
        
        for frame in 0..<Int(totalFrames) {
            var value: Float = 0
            
            if frame < tone1End {
                // First tone: 880Hz
                let envelope = cosineEnvelope(frame: frame, totalFrames: tone1End, sampleRate: sampleRate)
                value = Float(sin(2.0 * .pi * 880.0 * Double(frame) / sampleRate) * 0.8) * envelope
            } else if frame < gapEnd {
                // Gap: silence
                value = 0
            } else {
                // Second tone: 1320Hz
                let secondFrame = frame - gapEnd
                let secondTotal = Int(totalFrames) - gapEnd
                let envelope = cosineEnvelope(frame: secondFrame, totalFrames: secondTotal, sampleRate: sampleRate)
                value = Float(sin(2.0 * .pi * 1320.0 * Double(frame) / sampleRate) * 0.8) * envelope
            }
            
            pcmBuffer.floatChannelData?[0][frame] = value
            pcmBuffer.floatChannelData?[1][frame] = value
        }
        
        buffer.write(pcmBuffer)
    }

    /// Smooth cosine-half-window envelope for pleasant beep (no clicks).
    private func cosineEnvelope(frame: Int, totalFrames: Int, sampleRate: Double) -> Float {
        let fadeFrames = min(Int(sampleRate * 0.01), totalFrames / 4)  // 10ms or 1/4 of tone
        if frame < fadeFrames {
            let t = Float(frame) / Float(fadeFrames)
            return 0.5 - 0.5 * cos(.pi * t)  // Smooth cosine rise
        } else if frame > totalFrames - fadeFrames {
            let t = Float(totalFrames - frame) / Float(fadeFrames)
            return 0.5 - 0.5 * cos(.pi * t)  // Smooth cosine fall
        }
        return 1.0
    }

    // MARK: - Metronome

    private var metronomeTimer: DispatchSourceTimer?
    @Published var isMetronomeOn = false
    @Published var metronomeBPM: Int = 120

    func startMetronome(bpm: Int = 120) {
        guard !isMetronomeOn else { return }
        metronomeBPM = bpm
        isMetronomeOn = true
        let intervalNs = UInt64(60_000_000_000 / UInt64(bpm)) // nanoseconds per beat
        let queue = DispatchQueue(label: "com.audiosync.metronome", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.tickMetronome()
        }
        timer.resume()
        metronomeTimer = timer
        tickMetronome() // Immediate first tick
        DLog("[Metronome] Started at \(bpm) BPM")
    }

    func stopMetronome() {
        metronomeTimer?.cancel()
        metronomeTimer = nil
        isMetronomeOn = false
        DLog("[Metronome] Stopped")
    }

    func setMetronomeBPM(_ bpm: Int) {
        metronomeBPM = bpm
        if isMetronomeOn {
            stopMetronome()
            startMetronome(bpm: bpm)
        }
    }

    private func tickMetronome() {
        // Write clicks to ALL ring buffers — metronome is a diagnostic tool
        // that should output to every speaker regardless of volume/mute state.
        // The HAL render callback handles volume attenuation; we just ensure
        // the click data reaches every buffer.
        for uid in _bufferLookup.allKeys {
            if let rb = _bufferLookup.get(uid) {
                self.writeClick(to: rb, sampleRate: self.engineFormat.sampleRate)
            }
        }
    }

    private func writeClick(to buffer: DelayedRingBuffer, sampleRate: Double) {
        let clickDuration = 0.01 // 10ms click
        let totalFrames = AVAudioFrameCount(sampleRate * clickDuration)

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: totalFrames) else { return }
        pcmBuffer.frameLength = totalFrames

        for frame in 0..<Int(totalFrames) {
            let envelope = cosineEnvelope(frame: frame, totalFrames: Int(totalFrames), sampleRate: sampleRate)
            // 1000Hz sharp click
            let value = Float(sin(2.0 * .pi * 1000.0 * Double(frame) / sampleRate) * 0.9) * envelope
            pcmBuffer.floatChannelData?[0][frame] = value
            pcmBuffer.floatChannelData?[1][frame] = value
        }

        buffer.write(pcmBuffer)
    }

    /// Latest peak level from audio capture (for diagnostics)
    private let _lastTapPeak = AtomicFloat(0)

    // MARK: - Runtime Controls

    func updateDelay(for deviceUID: String, ms: Float) {
        guard let output = deviceOutputs[deviceUID] else { return }
        output.buffer.setDelay(ms: ms)
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

    func updateEQ(for deviceUID: String, bass: Float, treble: Float, mid: Float) {
        _bassLookup.set(deviceUID, bass)
        _trebleLookup.set(deviceUID, treble)
        _midLookup.set(deviceUID, mid)
        // Create EQ state if needed
        if _eqLookup.get(deviceUID) == nil {
            _eqLookup.set(deviceUID, SimpleEQ())
        }
    }

    /// Set the master volume multiplier (0...1). Applied on top of individual
    /// device volumes in the HAL render callback. This lets users scale all
    /// speakers proportionally without changing individual levels.
    func setMasterVolume(_ vol: Float) {
        _masterVolume.store(min(max(vol, 0), 1))
    }

    /// Set the global audio mode (normal, karaoke, vocal-boost).
    func setAudioMode(_ mode: AudioMode) {
        _audioMode.store(Float(mode.rawValue))
    }

    /// Configure a device as subwoofer with crossover frequency.
    func setSubwoofer(_ deviceUID: String, enabled: Bool, crossoverHz: Float = 80) {
        _subwooferLookup.set(deviceUID, enabled)
        _crossoverHzLookup.set(deviceUID, crossoverHz)
        if enabled {
            let lpf = CrossoverLPF()
            lpf.setCutoff(crossoverHz, sampleRate: Float(kEngineSampleRate))
            _crossoverLPFLookup.set(deviceUID, lpf)
        }
    }

    /// Set reverb/ambience preset for all active devices.
    func setReverb(_ preset: Reverb.Preset) {
        for uid in _reverbLookup.allKeys {
            if let rev = _reverbLookup.get(uid) {
                rev.setPreset(preset)
            }
        }
        _reverbPresetRaw.store(Float(preset.rawValue))
    }

    /// Reset all device EQ bands to flat (0). Returns the list of affected UIDs.
    @discardableResult
    func resetAllEQ() -> [String] {
        let uids = _bassLookup.allKeys
        for uid in uids {
            _bassLookup.set(uid, 0)
            _trebleLookup.set(uid, 0)
            _midLookup.set(uid, 0)
        }
        return uids
    }

    // MARK: - VU Meters

    /// Get the current peak level for a device (0.0...1.0). Returns 0 if not found.
    func peakLevel(for deviceUID: String) -> Float {
        _levelLookup.get(deviceUID) ?? 0
    }

    /// Get the end-to-end latency for a device (ms).
    func latency(for deviceUID: String) -> Float {
        _latencyLookup.get(deviceUID) ?? 0
    }

    /// Get health metrics for a device.
    func healthReport(for deviceUID: String) -> DeviceHealth {
        let wp: Int, rp: Int, fc: Int
        if let output = deviceOutputs[deviceUID] {
            wp = output.buffer.currentWritePos
            rp = output.buffer.currentReadPos
            fc = output.buffer.frameCountValue
        } else {
            wp = 0; rp = 0; fc = 1
        }
        let fill = Float(max(wp - rp, 0)) / Float(fc)
        return DeviceHealth(
            underrunCount: _underrunCountLookup.get(deviceUID) ?? 0,
            avgDrift: _driftLookup.get(deviceUID) ?? 0,
            bufferFillPercent: fill * 100,
            latencyMs: _latencyLookup.get(deviceUID) ?? 0
        )
    }

    // MARK: - Auto-Delay Compensation

    /// Measure per-device inherent latency by sampling ring buffer positions.
    /// Temporarily zeros all delays so ring buffer fill reflects hardware latency only
    /// (not our added delay). Differences in fill level reveal BT codec latency etc.
    @MainActor
    func measureLatencies(enabledUIDs: Set<String>, currentDelays: [String: Float] = [:], sampleCount: Int = 8) -> [String: Float] {
        // Step 1: Zero all delays so ring buffer fill = safetyFrames + hardware_latency
        for uid in enabledUIDs {
            if let output = deviceOutputs[uid] {
                output.buffer.setDelay(ms: 0)
            }
        }
        // Wait for buffers to settle at the new delay (reader needs a few cycles).
        // 500ms gives BT codecs enough time to stabilize after delay change.
        usleep(500_000) // 500ms settle time
        
        var samples: [String: [Float]] = [:]
        for uid in enabledUIDs {
            samples[uid] = []
        }
        
        // Step 2: Sample fill levels with zero delay
        for i in 0..<sampleCount {
            for uid in enabledUIDs {
                guard let output = deviceOutputs[uid] else { continue }
                let wp = output.buffer.currentWritePos
                let rp = output.buffer.currentReadPos
                let fillFrames = max(wp - rp, 0)
                let fillMs = Float(Double(fillFrames) / engineFormat.sampleRate * 1000.0)
                // Subtract safety margin — what remains is inherent hardware latency
                let safetyMs = Float(Double(kSafetyFrames) / engineFormat.sampleRate * 1000.0)
                let inherentMs = max(fillMs - safetyMs, 0)
                samples[uid]?.append(inherentMs)
            }
            if i < sampleCount - 1 {
                usleep(100_000) // 100ms between samples
            }
        }
        
        // Step 3: Restore original delays
        for uid in enabledUIDs {
            if let output = deviceOutputs[uid] {
                let originalDelay = currentDelays[uid] ?? 0
                output.buffer.setDelay(ms: originalDelay)
            }
        }
        
        // Average the samples
        var latencies: [String: Float] = [:]
        for (uid, vals) in samples where !vals.isEmpty {
            let avg = vals.reduce(0, +) / Float(vals.count)
            latencies[uid] = avg
            if let output = deviceOutputs[uid] {
                DLog("[AutoDelay] '\(output.device.name)': avg \(String(format: "%.1f", avg))ms inherent (samples: \(vals.map { String(format: "%.0f", $0) }.joined(separator: ", ")))")
            }
        }
        return latencies
    }

    /// Apply auto-delay compensation: most-delayed speaker = 0ms, others offset upward.
    /// Only considers devices in `enabledUIDs`.
    /// Measurement subtracts already-applied delay to get INHERENT latency,
    /// preventing oscillation when run multiple times.
    /// Returns the TOTAL delay (compensation only) keyed by device UID.
    @MainActor
    func applyAutoDelayCompensation(enabledUIDs: Set<String>, currentDelays: [String: Float] = [:]) -> [String: Float] {
        let latencies = measureLatencies(enabledUIDs: enabledUIDs, currentDelays: currentDelays)
        guard !latencies.isEmpty else { return [:] }
        let maxLatency = latencies.values.max() ?? 0

        var compensated: [String: Float] = [:]
        for (uid, latency) in latencies {
            // Compensation = how much EXTRA delay this device needs vs the most-delayed one
            let compensation = max(maxLatency - latency, 0)
            // Round to nearest 5ms for cleaner display
            let rounded = round(compensation / 5.0) * 5.0
            compensated[uid] = rounded
            if let output = deviceOutputs[uid] {
                output.buffer.setDelay(ms: rounded)
                DLog("[AutoDelay] '\(output.device.name)' → \(String(format: "%.0f", rounded))ms compensation (inherent \(String(format: "%.1f", latency))ms)")
            }
        }
        return compensated
    }

    // MARK: - Add / Remove Device

    func addDevice(_ device: AudioOutputDevice, settings: DeviceSettings) throws {
        guard deviceOutputs[device.uid] == nil else { return }

        DLog("Adding device '\(device.name)' (transport=\(device.transportType.rawValue), id=\(device.id), sr=\(device.sampleRate))...")

        let ringBuffer = DelayedRingBuffer()
        ringBuffer.setDelay(ms: settings.delayMs)

        // Register in lookup tables BEFORE setting render callback
        MultiOutputEngine.bufferLookup.set(device.uid, ringBuffer)
        MultiOutputEngine.volumeLookup.set(device.uid, settings.isMuted ? 0 : settings.volume)

        // Create per-device reverb instance (avoids shared-state races across audio threads)
        let rev = Reverb()
        rev.setPreset(Reverb.Preset(rawValue: Int(_reverbPresetRaw.load())) ?? .none)
        _reverbLookup.set(device.uid, rev)

        // Create per-device karaoke filter instance
        _karaokeBassLookup.set(device.uid, KaraokeFilter())

        // Create per-device EQ instance (for bass/treble controls)
        _eqLookup.set(device.uid, SimpleEQ())
        _bassLookup.set(device.uid, settings.bass)
        _trebleLookup.set(device.uid, settings.treble)

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

        // If engine is already running, start the HAL unit immediately
        // (otherwise start() will start it when called)
        if isRunning {
            let status = AudioOutputUnitStart(halUnit)
            if status != noErr {
                DLog("addDevice: AudioOutputUnitStart failed for '\(device.name)' (status \(status))")
            } else {
                DLog("addDevice: Started HAL unit for '\(device.name)' (engine already running)")
            }
        }
    }

    /// Check if a device is currently in the active output engine.
    func hasDevice(_ deviceUID: String) -> Bool {
        deviceOutputs[deviceUID] != nil
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
        _levelLookup.remove(deviceUID)
        _bassLookup.remove(deviceUID)
        _trebleLookup.remove(deviceUID)
        _midLookup.remove(deviceUID)
        _eqLookup.remove(deviceUID)
        _reverbLookup.remove(deviceUID)
        _karaokeBassLookup.remove(deviceUID)
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
        // CoreAudio inserts its own high-quality polyphase SRC for devices that need a different rate.
        var inputASBD = AudioStreamBasicDescription(
            mSampleRate: kEngineSampleRate,
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
    /// This makes our app-side volume slider the sole control for wired/Built-in devices.
    /// BT devices use AVRCP (not HAL volume) — our volume slider scales samples before
    /// sending to the HAL unit, which is the only reliable method for BT.
    /// System notification sounds bypass our routing entirely — they go through
    /// macOS's dedicated alert sound path, not through BlackHole.
    private static func setDeviceVolumeMax(_ deviceID: AudioObjectID) {
        for ch in [0, 1] {
            // Try kAudioDevicePropertyVolumeScalar (direct channel volume — works on wired/built-in)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: UInt32(ch))
            var vol: Float = 1.0
            let size = UInt32(MemoryLayout<Float>.size)
            var writable: DarwinBoolean = false
            let canSet = AudioObjectIsPropertySettable(deviceID, &addr, &writable)
            if canSet == noErr && writable.boolValue {
                let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
                if status == noErr {
                    DLog("Set device \\(deviceID) ch\\(ch) volume to max (VolumeScalar)")
                }
            }
        }
        
        // Fallback for BT: use VirtualMasterVolume (controls macOS volume slider)
        var vmAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vmVol: Float = 1.0
        let vmSize = UInt32(MemoryLayout<Float>.size)
        var vmWritable: DarwinBoolean = false
        let vmCanSet = AudioObjectIsPropertySettable(deviceID, &vmAddr, &vmWritable)
        if vmCanSet == noErr && vmWritable.boolValue {
            let status = AudioObjectSetPropertyData(deviceID, &vmAddr, 0, nil, vmSize, &vmVol)
            if status == noErr {
                DLog("Set device \\(deviceID) VirtualMasterVolume to max")
            }
        }
    }

    // Saved system volumes for restore on stop: [deviceID: volume]
    private var savedSystemVolumes: [AudioObjectID: Float] = [:]
    private var savedDefaultDeviceVolume: Float = 1.0
    private var savedDefaultDeviceID: AudioObjectID = 0
    // Saved mute state: [deviceID: wasMuted]
    private var savedMuteStates: [AudioObjectID: Bool] = [:]

    /// Read current system volume for each device and save it.
    /// Also saves the default output device's volume (NC slider).
    /// Call BEFORE configuring the engine (which sets volumes to max).
    /// captureDeviceID is excluded to avoid interfering with the capture IOProc.
    @MainActor
    func saveSystemVolumes(devices: [AudioOutputDevice], captureDeviceID: AudioObjectID? = nil) {
        savedSystemVolumes.removeAll()
        savedMuteStates.removeAll()
        for device in devices where device.id != captureDeviceID {
            let vol = Self.readDeviceVolume(device.id)
            savedSystemVolumes[device.id] = vol
            let muted = Self.readDeviceMute(device.id)
            savedMuteStates[device.id] = muted
            DLog("[Volume] Saved '\(device.name)' system volume: \(vol), muted: \(muted)")
        }
        // Save the default output device volume (what NC slider controls),
        // but skip if the default is the capture device (BlackHole) — we don't touch it.
        if let capID = captureDeviceID {
            var defaultID: AudioObjectID = 0
            var sz = UInt32(MemoryLayout<AudioObjectID>.size)
            var defAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &sz, &defaultID) == noErr, defaultID != 0, defaultID != capID {
                savedDefaultDeviceID = defaultID
                savedDefaultDeviceVolume = Self.readDeviceVolume(defaultID)
                DLog("[Volume] Saved default device (id=\(defaultID)) volume: \(savedDefaultDeviceVolume)")
            }
        }
    }

    /// Restore previously saved system volumes and mute states after routing stops.
    @MainActor
    func restoreSystemVolumes() {
        for (deviceID, vol) in savedSystemVolumes {
            Self.setDeviceVolume(deviceID, vol)
            // Restore mute state
            if let wasMuted = savedMuteStates[deviceID] {
                Self.setDeviceMute(deviceID, wasMuted)
                DLog("[Volume] Restored device \(deviceID) volume to \(vol), muted: \(wasMuted)")
            } else {
                DLog("[Volume] Restored device \(deviceID) volume to \(vol)")
            }
        }
        // Restore default device volume (NC slider)
        if savedDefaultDeviceID != 0 {
            Self.setDeviceVolume(savedDefaultDeviceID, savedDefaultDeviceVolume)
            DLog("[Volume] Restored default device (id=\(savedDefaultDeviceID)) volume to \(savedDefaultDeviceVolume)")
        }
        savedSystemVolumes.removeAll()
        savedMuteStates.removeAll()
        savedDefaultDeviceID = 0
        savedDefaultDeviceVolume = 1.0
    }

    /// Set a specific device's system volume to max and unmute it (public wrapper).
    @MainActor
    func setDeviceVolumeToMax(_ deviceID: AudioObjectID) {
        Self.setDeviceMute(deviceID, false)
        Self.setDeviceVolumeMax(deviceID)
    }

    /// Set the current default output device's volume to max.
    /// This is the device the macOS notification center volume slider controls.
    @MainActor
    func setDefaultDeviceVolumeMax() {
        var defaultID: AudioObjectID = 0
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &sz, &defaultID) == noErr, defaultID != 0 else {
            DLog("[Volume] Could not read default output device")
            return
        }
        Self.setDeviceMute(defaultID, false)
        Self.setDeviceVolume(defaultID, 1.0)
        DLog("[Volume] Set default device (id=\(defaultID)) volume to max, unmuted")
    }

    /// Read a device's current system volume (0...1). Tries VirtualMasterVolume first
    /// (covers BT + wired), falls back to averaging L+R channel VolumeScalar.
    private static func readDeviceVolume(_ deviceID: AudioObjectID) -> Float {
        // Try VirtualMasterVolume first (works for BT and wired)
        var vmAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vmVol: Float = 0
        var vmSize = UInt32(MemoryLayout<Float>.size)
        let vmStatus = AudioObjectGetPropertyData(deviceID, &vmAddr, 0, nil, &vmSize, &vmVol)
        if vmStatus == noErr {
            return vmVol
        }
        // Fallback: average of channel 0 and 1 VolumeScalar
        var sum: Float = 0
        var count: Float = 0
        for ch in [0, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: UInt32(ch))
            var vol: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol)
            if status == noErr {
                sum += vol
                count += 1
            }
        }
        return count > 0 ? sum / count : 1.0
    }

    /// Set a device's system volume (0...1).
    private static func setDeviceVolume(_ deviceID: AudioObjectID, _ volume: Float) {
        // Try VirtualMasterVolume first (works for BT and wired)
        var vmAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vmVol = volume
        var vmWritable: DarwinBoolean = false
        let vmCanSet = AudioObjectIsPropertySettable(deviceID, &vmAddr, &vmWritable)
        if vmCanSet == noErr && vmWritable.boolValue {
            let status = AudioObjectSetPropertyData(deviceID, &vmAddr, 0, nil, UInt32(MemoryLayout<Float>.size), &vmVol)
            if status == noErr {
                DLog("Restored device \(deviceID) VirtualMasterVolume to \(volume)")
                return
            }
        }
        // Fallback: per-channel VolumeScalar
        for ch in [0, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: UInt32(ch))
            var vol = volume
            var writable: DarwinBoolean = false
            let canSet = AudioObjectIsPropertySettable(deviceID, &addr, &writable)
            if canSet == noErr && writable.boolValue {
                AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &vol)
            }
        }
    }

    /// Read a device's current mute state. Tries master channel first,
    /// falls back to channel 0.
    private static func readDeviceMute(_ deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        // Fallback: channel 0
        addr.mElement = 0
        if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return false
    }

    /// Set a device's mute state. Tries master channel first, falls back to channels 0+1.
    private static func setDeviceMute(_ deviceID: AudioObjectID, _ muted: Bool) {
        var val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        // Try master element
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var writable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(deviceID, &addr, &writable) == noErr && writable.boolValue {
            if AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &val) == noErr {
                DLog("[Mute] Set device \(deviceID) muted=\(muted) (master)")
                return
            }
        }
        // Fallback: per-channel
        for ch in [0, 1] {
            addr.mElement = UInt32(ch)
            writable = false
            if AudioObjectIsPropertySettable(deviceID, &addr, &writable) == noErr && writable.boolValue {
                AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &val)
            }
        }
        DLog("[Mute] Set device \(deviceID) muted=\(muted) (per-channel)")
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

        // CPU overload guard: if CPU usage is critical, output silence to prevent
        // audio glitches from missed deadlines. The cpuTimer updates cpuUsage every 0.5s.
        if _cpuOverloadFlag.load() > 0 {
            DelayedRingBuffer.fillSilence(ioData, frames: inNumberFrames)
            return noErr
        }

        // Look up ring buffer and volume — if either is missing, output silence
        guard let rb = _bufferLookup.get(uid) else {
            DelayedRingBuffer.fillSilence(ioData, frames: inNumberFrames)
            return noErr
        }

        let individualVol = _volumeLookup.get(uid) ?? 0
        let masterVol = _masterVolume.load()
        let vol = individualVol * masterVol

        if vol < 0.001 {
            DelayedRingBuffer.fillSilence(ioData, frames: inNumberFrames)
            return noErr
        }

        rb.read(into: ioData, frames: inNumberFrames)

        // Sync health metrics from ring buffer to lookups
        _underrunCountLookup.set(uid, rb.underrunCount)
        _driftLookup.set(uid, Float(rb.lastDrift))

        // Apply volume scaling if not 1.0
        if vol < 0.999 {
            DelayedRingBuffer.applyVolume(vol, to: ioData, frames: inNumberFrames)
        }

        // Apply reverb if enabled (per-device instance)
        // CRITICAL: Process mono (L+R)/2 through ONE delay line, then add wet to both channels.
        // Processing L-block then R-block through the same delay line corrupts the reverb state.
        if let rev = _reverbLookup.get(uid), rev.isEnabled {
            let ablR = UnsafeMutableAudioBufferListPointer(ioData)
            if ablR.count >= 2, let leftData = ablR[0].mData, let rightData = ablR[1].mData {
                let leftPtr = leftData.assumingMemoryBound(to: Float.self)
                let rightPtr = rightData.assumingMemoryBound(to: Float.self)
                let count = Int(ablR[0].mDataByteSize / UInt32(MemoryLayout<Float>.size))
                let wm = rev.wetMix
                for i in 0..<count {
                    let mono = (leftPtr[i] + rightPtr[i]) * 0.5
                    let wet = rev.processWet(mono) * wm
                    leftPtr[i] += wet
                    rightPtr[i] += wet
                }
            } else {
                // Mono: process directly
                for buf in ablR {
                    guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    let count = Int(buf.mDataByteSize / UInt32(MemoryLayout<Float>.size))
                    for i in 0..<count {
                        ptr[i] = rev.process(ptr[i])
                    }
                }
            }
        }

        // Apply subwoofer crossover (low-pass filter) if device is configured as subwoofer
        if _subwooferLookup.get(uid) == true, let lpf = _crossoverLPFLookup.get(uid) {
            let ablSub = UnsafeMutableAudioBufferListPointer(ioData)
            for buf in ablSub {
                guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                let count = Int(buf.mDataByteSize / UInt32(MemoryLayout<Float>.size))
                for i in 0..<count {
                    ptr[i] = lpf.process(ptr[i])
                }
            }
        }

        // Apply audio mode processing (karaoke center-cancel, vocal boost, or EQ)
        let modeRaw = _audioMode.load()
        let abl2 = UnsafeMutableAudioBufferListPointer(ioData)
        if modeRaw == 1 {  // karaoke: aggressive vocal removal — zero center, preserve bass only
            if abl2.count >= 2, let leftData = abl2[0].mData, let rightData = abl2[1].mData {
                let leftPtr = leftData.assumingMemoryBound(to: Float.self)
                let rightPtr = rightData.assumingMemoryBound(to: Float.self)
                let count = Int(abl2[0].mDataByteSize / UInt32(MemoryLayout<Float>.size))
                let bassFilter = _karaokeBassLookup.get(uid)
                for i in 0..<count {
                    let center = (leftPtr[i] + rightPtr[i]) * 0.5
                    let side = (leftPtr[i] - rightPtr[i]) * 0.5
                    // Extract only bass from center (vocals live above ~200Hz)
                    let bassOnly = bassFilter?.process(center) ?? center
                    leftPtr[i] = side + bassOnly
                    rightPtr[i] = -side + bassOnly
                }
            }
        } else if modeRaw == 2 {  // vocal boost: amplify mid frequencies
            if let eq = _eqLookup.get(uid) {
                for buf in abl2 {
                    guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    let count = Int(buf.mDataByteSize / UInt32(MemoryLayout<Float>.size))
                    for i in 0..<count {
                        // Boost mid (vocals) with +0.7, leave bass/treble flat
                        ptr[i] = eq.process(ptr[i], bass: 0, treble: 0, mid: 0.7)
                    }
                }
            }
        }

        // Per-device bass/treble EQ (applied in all modes)
        let bassGain = _bassLookup.get(uid) ?? 0
        let trebleGain = _trebleLookup.get(uid) ?? 0
        if bassGain != 0 || trebleGain != 0 {
            if let eq = _eqLookup.get(uid) {
                for buf in abl2 {
                    guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    let count = Int(buf.mDataByteSize / UInt32(MemoryLayout<Float>.size))
                    for i in 0..<count {
                        ptr[i] = eq.process(ptr[i], bass: bassGain, treble: trebleGain, mid: 0)
                    }
                }
            }
        }

        // End-to-end latency measurement
        let now = mach_absolute_time()
        let captured = _captureTimestamp.load()
        if captured > 0 && captured <= now {
            var info = mach_timebase_info()
            mach_timebase_info(&info)
            let diff = now - captured
            // Use overflowing multiply to prevent UInt64 trap on large diffs
            let (product, overflowed) = diff.multipliedReportingOverflow(by: UInt64(info.numer))
            let elapsed = overflowed ? UInt64.max : product / UInt64(info.denom)
            let latencyMs = Float(elapsed) / 1_000_000
            _latencyLookup.set(uid, latencyMs)
        }

        // VU meter: measure peak level after volume (non-blocking, ~200ns)
        var peak: Float = 0
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        for buf in abl {
            guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
            let ptr = data.assumingMemoryBound(to: Float.self)
            let count = Int(buf.mDataByteSize / UInt32(MemoryLayout<Float>.size))
            for i in 0..<min(count, 256) {  // ponytail: sample first 256 frames — fast, good approximation
                let v = abs(ptr[i])
                if v > peak { peak = v }
            }
        }
        _levelLookup.set(uid, peak)

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
                // Require sustained overload (3 consecutive readings >95%) before silencing.
                // A single spike from starting HAL units should not kill audio.
                if cpuUsage > 95 {
                    cpuOverloadCount += 1
                    if cpuOverloadCount >= 3 {
                        _cpuOverloadFlag.store(1)
                        DLog("[CPU Guard] Sustained overload (\(String(format: "%.1f", cpuUsage))%) — outputting silence")
                    }
                } else {
                    cpuOverloadCount = 0
                    if cpuUsage < 70 {
                        _cpuOverloadFlag.store(0)
                    }
                }
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
