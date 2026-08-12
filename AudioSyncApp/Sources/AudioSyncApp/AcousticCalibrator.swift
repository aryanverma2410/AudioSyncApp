import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import SwiftUI

// MARK: - Acoustic Calibrator
// Experimental feature: measures real speaker latency by playing calibrated chirps
// and detecting when they arrive at the MacBook microphone via cross-correlation.
//
// Algorithm:
// 1. Play a frequency-sweep chirp (1000→2000Hz, 50ms) on one speaker
// 2. Record mic input continuously
// 3. Cross-correlate the known chirp template against the recorded signal
// 4. Peak of cross-correlation = arrival time
// 5. Repeat for each speaker, compute relative offsets → delay values
// 6. Cross-check: all speakers chirp simultaneously with unique freq bands

// MARK: - Calibration State

enum CalibratorState: String, CaseIterable {
    case idle = "Idle"
    case requestingPermission = "Requesting Permission"
    case measuring = "Measuring"
    case crossChecking = "Cross-Checking"
    case done = "Done"
    case failed = "Failed"
}

// MARK: - Calibration Result (per device)

struct DeviceCalibrationResult: Identifiable, Equatable {
    let id = UUID()
    let deviceUID: String
    let deviceName: String
    /// Milliseconds from chirp start to mic arrival. 0 = not measured.
    var arrivalMs: Float?
    /// Recommended delay compensation (relative to fastest speaker).
    var recommendedDelayMs: Float?
    /// Confidence: 0 = uncertain, 1 = high confidence
    var confidence: Float = 0

    var isMeasured: Bool { arrivalMs != nil }
}

// MARK: - Acoustic Calibrator

@MainActor
final class AcousticCalibrator: ObservableObject {
    @Published var state: CalibratorState = .idle
    @Published var results: [String: DeviceCalibrationResult] = [:]
    @Published var currentDeviceIndex: Int = 0
    @Published var totalDevices: Int = 0
    @Published var errorMessage: String?

    // Mic capture state
    private var micDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var micBuffer: [Float] = []
    private var micSampleRate: Double = 48000
    private var micBufferLock = os_unfair_lock_s()
    private var isRecording = false

    // Chirp template (known signal for cross-correlation)
    private var chirpTemplate: [Float] = []
    private let chirpDurationSec: Double = 0.06  // 60ms chirp
    private let chirpFreqStart: Float = 1000    // Hz
    private let chirpFreqEnd: Float = 2000      // Hz
    private let chirpAmplitude: Float = 0.9

    // Engine format for chirp generation
    private let engineFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    // Reference to engine for injecting chirps
    weak var outputEngine: MultiOutputEngine?

    init(outputEngine: MultiOutputEngine? = nil) {
        self.outputEngine = outputEngine
        generateChirpTemplate()
    }

    // MARK: - Chirp Generation

    /// Generate a linear frequency-sweep chirp (1000→2000Hz, 60ms).
    /// Stored as mono template; copied to both L&R channels when played.
    private func generateChirpTemplate() {
        let sampleRate = Float(engineFormat.sampleRate)
        let totalFrames = Int(chirpDurationSec * Double(sampleRate))
        chirpTemplate = [Float](repeating: 0, count: totalFrames)

        var phase: Float = 0

        for i in 0..<totalFrames {
            let progress = Float(i) / Float(totalFrames)
            // Linear frequency sweep
            let freq = chirpFreqStart + (chirpFreqEnd - chirpFreqStart) * progress
            // Instantaneous phase increment = 2π * f / sampleRate
            phase += 2.0 * Float.pi * freq / sampleRate
            // Cosine envelope (smooth on/off — no clicks)
            let envelope: Float
            let fadeFrames = Int(sampleRate * 0.008) // 8ms fade
            if i < fadeFrames {
                envelope = 0.5 - 0.5 * cos(Float.pi * Float(i) / Float(fadeFrames))
            } else if i > totalFrames - fadeFrames {
                envelope = 0.5 - 0.5 * cos(Float.pi * Float(totalFrames - i) / Float(fadeFrames))
            } else {
                envelope = 1.0
            }
            chirpTemplate[i] = chirpAmplitude * envelope * sin(phase)
        }
    }

    /// Create a stereo AVAudioPCMBuffer containing the chirp.
    private func chirpPCMBuffer() -> AVAudioPCMBuffer? {
        let totalFrames = AVAudioFrameCount(chirpTemplate.count)
        guard let buf = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: totalFrames) else { return nil }
        buf.frameLength = totalFrames
        for ch in 0..<2 {
            guard let channelData = buf.floatChannelData?[ch] else { continue }
            for i in 0..<Int(totalFrames) {
                channelData[i] = chirpTemplate[i]
            }
        }
        return buf
    }

    // MARK: - Public API

    /// Run the full calibration sequence:
    /// 1. Request mic permission
    /// 2. Start mic recording
    /// 3. Sequential: chirp each speaker, measure arrival
    /// 4. Cross-check: all speakers chirp, verify alignment
    /// 5. Compute delay recommendations
    func startCalibration(deviceUIDs: [(uid: String, name: String)]) async {
        guard state == .idle || state == .done || state == .failed else { return }
        errorMessage = nil
        results = [:]

        // Initialize results
        for (_, device) in deviceUIDs.enumerated() {
            results[device.uid] = DeviceCalibrationResult(
                deviceUID: device.uid,
                deviceName: device.name
            )
        }
        totalDevices = deviceUIDs.count
        currentDeviceIndex = 0

        // Step 1: Microphone permission
        state = .requestingPermission
        let granted = await requestMicPermission()
        guard granted else {
            state = .failed
            errorMessage = "Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone."
            return
        }

        // Step 2: Start mic capture
        guard startMicCapture() else {
            state = .failed
            errorMessage = "Failed to start microphone capture. Check mic connectivity."
            return
        }

        // Brief settle for mic to start capturing
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Step 3: Sequential measurement — one speaker at a time
        state = .measuring
        var arrivalTimes: [String: Float] = [:] // uid → arrival in ms

        for (index, device) in deviceUIDs.enumerated() {
            currentDeviceIndex = index
            DLog("[Calibrator] Measuring speaker \(index + 1)/\(deviceUIDs.count): '\(device.name)'")

            // Clear mic buffer
            clearMicBuffer()

            // Play chirp on this speaker and record arrival
            let arrivalMs = await measureSingleDevice(uid: device.uid)
            arrivalTimes[device.uid] = arrivalMs
            results[device.uid]?.arrivalMs = arrivalMs

            // Gap between measurements (avoid overlap)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        // Step 4: Compute relative delays
        computeRecommendations(arrivalTimes: arrivalTimes)

        // Done
        stopMicCapture()
        state = .done
        DLog("[Calibrator] Calibration complete. Results: \(results.mapValues { $0.arrivalMs ?? -1 })")
    }

    /// Cancel ongoing calibration.
    func cancelCalibration() {
        stopMicCapture()
        state = .idle
        errorMessage = nil
    }

    // MARK: - Single Device Measurement

    /// Play a chirp on a specific device, listen via mic, return arrival time in ms.
    private func measureSingleDevice(uid: String) async -> Float {
        // Clear buffer and start recording
        isRecording = true
        clearMicBuffer()

        // Inject chirp into this device's ring buffer
        outputEngine?.injectCalibrationChirp(for: uid)

        // Wait for chirp to travel through the pipeline + air + be captured
        // Max expected round-trip: ~500ms (200ms BT latency + 100ms air + margins)
        // Wait 1 second to ensure capture
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        isRecording = false

        // Get recorded mic data
        let recordedSamples = getMicSamples()

        // Cross-correlate chirp template against recorded signal
        let (arrivalOffsetSamples, peakStrength) = crossCorrelate(template: chirpTemplate, signal: recordedSamples)

        // Convert sample offset to milliseconds from send time
        // The offset from cross-correlation is the delay in samples from the
        // START of the recording. But our recording started before the chirp
        // was sent (because we cleared the buffer first).
        // The chirp takes some time to reach the mic:
        //   pipeline_delay + BT_codec_latency + air_travel_time
        // We measure from when we injected the chirp to when it arrives at mic.
        let sampleRate = Float(engineFormat.sampleRate)
        let arrivalMs = Float(arrivalOffsetSamples) / sampleRate * 1000.0

        // Confidence: stronger correlation peak = higher confidence
        results[uid]?.confidence = min(peakStrength / 0.3, 1.0) // 0.3 threshold

        DLog("[Calibrator] '\(uid)': arrival=\(String(format: "%.1f", arrivalMs))ms, confidence=\(String(format: "%.2f", min(peakStrength / 0.3, 1.0)))")
        return max(arrivalMs, 0)
    }

    // MARK: - Cross-Correlation

    /// Cross-correlate template against signal. Returns (sample offset, peak NCC strength).
    private func crossCorrelate(template: [Float], signal: [Float]) -> (offset: Int, ncc: Float) {
        guard template.count > 0, signal.count > template.count else { return (0, 0) }

        let templateLen = template.count
        let searchLen = signal.count - templateLen
        guard searchLen > 0 else { return (0, 0) }

        var templateEnergy: Float = 0
        for i in 0..<templateLen { templateEnergy += template[i] * template[i] }
        guard templateEnergy > 0 else { return (0, 0) }

        var bestOffset = 0
        var bestNCC: Float = -1

        let step = 4
        for offset in stride(from: 0, to: searchLen, by: step) {
            var correlation: Float = 0
            var signalEnergy: Float = 0

            for i in 0..<templateLen {
                let s = signal[offset + i]
                correlation += template[i] * s
                signalEnergy += s * s
            }

            let denominator = sqrt(templateEnergy * signalEnergy)
            if denominator > 0.001 {
                let ncc = correlation / denominator
                if ncc > bestNCC {
                    bestNCC = ncc
                    bestOffset = offset
                }
            }
        }

        // Refine: search ±step around best with step=1
        let refineStart = max(0, bestOffset - step)
        let refineEnd = min(searchLen, bestOffset + step)
        for offset in refineStart..<refineEnd {
            var correlation: Float = 0
            var signalEnergy: Float = 0

            for i in 0..<templateLen {
                let s = signal[offset + i]
                correlation += template[i] * s
                signalEnergy += s * s
            }

            let denominator = sqrt(templateEnergy * signalEnergy)
            if denominator > 0.001 {
                let ncc = correlation / denominator
                if ncc > bestNCC {
                    bestNCC = ncc
                    bestOffset = offset
                }
            }
        }

        return (bestOffset, max(bestNCC, 0))
    }

    // MARK: - Recommendations

    /// Compute recommended delay for each device so all arrivals align.
    /// The fastest speaker gets 0ms delay; others get offset to match.
    private func computeRecommendations(arrivalTimes: [String: Float]) {
        // Find minimum arrival time (fastest speaker)
        let measuredArrivals = arrivalTimes.filter { $0.value > 0 }
        guard !measuredArrivals.isEmpty else { return }

        let minArrival = measuredArrivals.values.min() ?? 0

        for (uid, arrival) in arrivalTimes {
            let compensation = max(arrival - minArrival, 0)
            // Round to 5ms for cleaner display
            let rounded = round(compensation / 5.0) * 5.0
            results[uid]?.recommendedDelayMs = rounded
        }
    }

    /// Apply calibration results to the app state (set delays).
    func applyResults(to appState: AppState) {
        for (uid, result) in results {
            if let delay = result.recommendedDelayMs {
                appState.updateDelay(uid, ms: delay)
            }
        }
    }

    // MARK: - Microphone Permission

    private func requestMicPermission() async -> Bool {
        // AVCaptureDevice requires Info.plist key NSMicrophoneUsageDescription
        // which is in our Resources/Info.plist
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Microphone Capture (CoreAudio)

    private func startMicCapture() -> Bool {
        // Find default input device
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else {
            DLog("[Calibrator] No default input device found")
            return false
        }

        micDeviceID = deviceID

        // Get device sample rate
        var srAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var sampleRate: Float64 = 48000.0
        var srSize = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(deviceID, &srAddr, 0, nil, &srSize, &sampleRate) == noErr {
            micSampleRate = sampleRate
        }

        DLog("[Calibrator] Using mic device \(deviceID) at \(micSampleRate)Hz")

        // Create IOProc
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(deviceID, Self.micIOProc, selfPtr, &procID)
        guard status == noErr, let pid = procID else {
            DLog("[Calibrator] Failed to create IOProc: \(status)")
            return false
        }
        ioProcID = pid

        // Start
        micBuffer = []
        let startStatus = AudioDeviceStart(deviceID, pid)
        guard startStatus == noErr else {
            DLog("[Calibrator] Failed to start IOProc: \(startStatus)")
            AudioDeviceDestroyIOProcID(deviceID, pid)
            ioProcID = nil
            return false
        }

        DLog("[Calibrator] Mic capture started")
        return true
    }

    private func stopMicCapture() {
        if let pid = ioProcID, micDeviceID != 0 {
            AudioDeviceStop(micDeviceID, pid)
            AudioDeviceDestroyIOProcID(micDeviceID, pid)
            ioProcID = nil
            DLog("[Calibrator] Mic capture stopped")
        }
    }

    /// The IOProc callback — called by CoreAudio on the audio thread.
    /// Copies input samples into our buffer (thread-safe via os_unfair_lock).
    private static let micIOProc: AudioDeviceIOProc = { _, _, inputABL, _, _, _, clientData -> OSStatus in
        guard let clientData else { return noErr }
        let self_ = Unmanaged<AcousticCalibrator>.fromOpaque(clientData).takeUnretainedValue()

        guard self_.isRecording else { return noErr }

        // inputABL is UnsafePointer<AudioBufferList>
        let mutablePtr = UnsafeMutablePointer<AudioBufferList>(mutating: inputABL)
        let abl = UnsafeMutableAudioBufferListPointer(mutablePtr)

        for buf in abl {
            guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size

            os_unfair_lock_lock(&self_.micBufferLock)
            for i in 0..<count {
                self_.micBuffer.append(floatPtr[i])
            }
            os_unfair_lock_unlock(&self_.micBufferLock)
        }

        return noErr
    }

    private func clearMicBuffer() {
        os_unfair_lock_lock(&micBufferLock)
        micBuffer = []
        os_unfair_lock_unlock(&micBufferLock)
    }

    private func getMicSamples() -> [Float] {
        os_unfair_lock_lock(&micBufferLock)
        let copy = micBuffer
        os_unfair_lock_unlock(&micBufferLock)
        return copy
    }
}
