import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreAudio
import AudioToolbox
import AppKit

// MARK: - System Audio Capturer
// Captures system audio via CoreAudio device IOProc on a virtual device (BlackHole).
// No TCC permission needed — unlike SCStream which requires Screen Recording.
// Falls back to SCStream only if no virtual device found.

@MainActor
final class SystemAudioCapturer: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var captureError: String?
    @Published var captureMethod: CaptureMethod = .none

    enum CaptureMethod: String {
        case none = "None"
        case coreAudio = "CoreAudio"
        case scStream = "SCStream"
    }

    // Thread-safe callback box (accessible from any queue)
    let callbackBox = CallbackBox()

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { callbackBox.callback }
        set { callbackBox.callback = newValue }
    }

    let engineFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    // CoreAudio state
    private var captureDeviceID: AudioObjectID = 0
    var _captureDeviceID: AudioObjectID { captureDeviceID }
    private var ioProcID: AudioDeviceIOProcID?
    private var originalDefaultDeviceID: AudioObjectID = 0
    private var didSetBlackHoleAsDefault = false

    /// The ID of the device being used for capture (nil if not capturing or using SCStream)
    var activeCaptureDeviceID: AudioObjectID? {
        return (captureMethod == .coreAudio && captureDeviceID != 0) ? captureDeviceID : nil
    }

    // SCStream state
    private var scStream: SCStreamProxy?
}

// MARK: - Callback Box (thread-safe, nonisolated)

final class CallbackBox: @unchecked Sendable {
    var callback: ((AVAudioPCMBuffer) -> Void)?
    var bufferCount: Int = 0

    /// Pre-allocated buffer reused by IOProc — eliminates malloc on audio thread.
    /// ponytail: single buffer assumes IOProc is non-concurrent (true for CoreAudio — one IO thread per device).
    var reusableBuffer: AVAudioPCMBuffer?
}

// MARK: - Start / Stop

extension SystemAudioCapturer {

    func startCapture() async throws {
        guard !isCapturing else { return }
        captureError = nil
        callbackBox.bufferCount = 0

        // Method 1: CoreAudio tap on virtual device (no TCC needed)
        if let deviceID = findVirtualDevice() {
            DLog("[Capture] Using CoreAudio tap on virtual device id=\(deviceID)")
            try startCoreAudioTap(deviceID: deviceID)
            captureMethod = .coreAudio
            isCapturing = true
            return
        }

        // Method 2: SCStream fallback (needs Screen Recording permission)
        DLog("[Capture] No virtual device, falling back to SCStream")
        try await startSCStream()
        captureMethod = .scStream
        isCapturing = true
    }

    func stopCapture() {
        guard isCapturing else { return }
        switch captureMethod {
        case .coreAudio: stopCoreAudioTap()
        case .scStream: stopSCStream()
        default: break
        }
        isCapturing = false
        captureMethod = .none
    }
}

// MARK: - Method 1: CoreAudio Device Tap

extension SystemAudioCapturer {

    private func findVirtualDevice() -> AudioObjectID? {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }

        // FIXME: Add guard clause for sample rate mismatch
        let virtualNames = ["BlackHole", "Soundflower", "Loopback", "GroundControl"]
        for id in ids {
            let name = deviceName(id)
            for vn in virtualNames where name.localizedCaseInsensitiveContains(vn) {
                if hasOutput(id) {
                    DLog("[Capture] Found virtual device '\(name)' (id=\(id))")
                    return id
                }
            }
        }
        return nil
    }

    private func startCoreAudioTap(deviceID: AudioObjectID) throws {
        captureDeviceID = deviceID

        // Save current default
        var defaultID: AudioObjectID = 0
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &defaultID) == noErr {
            originalDefaultDeviceID = defaultID
            DLog("[Capture] Saved default device id=\(defaultID)")
        }

        // Set virtual device as default so all system audio goes through it
        var bhID = deviceID
        let setStatus = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &bhID)
        if setStatus != noErr && defaultID != deviceID {
            DLog("[Capture] ERROR: Can't set virtual device as default (status \(setStatus))")
            throw CaptureError.deviceUnavailable
        }
        didSetBlackHoleAsDefault = (defaultID != deviceID)
        DLog("[Capture] Set virtual device as default output")

        // Create IOProc
        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(deviceID, Self.coreAudioIOProc, Unmanaged.passUnretained(self).toOpaque(), &procID)
        guard createStatus == noErr, let pid = procID else {
            DLog("[Capture] ERROR: AudioDeviceCreateIOProcID failed (\(createStatus))")
            restoreDefault()
            throw CaptureError.deviceUnavailable
        }
        ioProcID = pid

        // Pre-allocate reusable buffer for IOProc — eliminates malloc on audio thread.
        // 4096 frames covers any IO buffer size (typical: 256–4096).
        callbackBox.reusableBuffer = AVAudioPCMBuffer(pcmFormat: engineFormat, frameCapacity: 4096)

        // Start IOProc
        let startStatus = AudioDeviceStart(deviceID, pid)
        guard startStatus == noErr else {
            DLog("[Capture] ERROR: AudioDeviceStart failed (\(startStatus))")
            AudioDeviceDestroyIOProcID(deviceID, pid)
            ioProcID = nil
            restoreDefault()
            throw CaptureError.deviceUnavailable
        }
        DLog("[Capture] CoreAudio IOProc started on device \(deviceID)")
    }

    private func stopCoreAudioTap() {
        if let pid = ioProcID, captureDeviceID != 0 {
            AudioDeviceStop(captureDeviceID, pid)
            AudioDeviceDestroyIOProcID(captureDeviceID, pid)
            ioProcID = nil
            DLog("[Capture] CoreAudio IOProc stopped (received \(callbackBox.bufferCount) buffers)")
        }
        restoreDefault()
    }

    private func restoreDefault() {
        guard didSetBlackHoleAsDefault, originalDefaultDeviceID != 0 else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var devID = originalDefaultDeviceID
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &devID)
        if status == noErr {
            DLog("[Capture] Restored default device id=\(originalDefaultDeviceID)")
        } else {
            DLog("[Capture] ERROR: Can't restore default device (\(status))")
        }
        didSetBlackHoleAsDefault = false
    }

    // The IOProc callback — called by CoreAudio on audio thread (realtime-safe, zero allocation)
    private static let coreAudioIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData -> OSStatus in
        guard let clientData else { return noErr }
        let self_ = Unmanaged<SystemAudioCapturer>.fromOpaque(clientData).takeUnretainedValue()
        let mutableABL = UnsafeMutablePointer<AudioBufferList>(mutating: inputData)
        let buffers = UnsafeMutableAudioBufferListPointer(mutableABL)

        // Count frames
        var frames: UInt32 = 0
        for buf in buffers where buf.mDataByteSize > 0 {
            frames = max(frames, buf.mDataByteSize / (UInt32(MemoryLayout<Float>.size) * buf.mNumberChannels))
        }
        guard frames > 0, frames <= 4096 else { return noErr }

        // Reuse pre-allocated buffer — NO malloc
        guard let pcm = self_.callbackBox.reusableBuffer else { return noErr }
        pcm.frameLength = frames

        if buffers.count >= 2, let ld = buffers[0].mData, let rd = buffers[1].mData {
            // Non-interleaved (BlackHole standard format)
            let lf = min(Int(buffers[0].mDataByteSize / UInt32(MemoryLayout<Float>.size)), Int(frames))
            let rf = min(Int(buffers[1].mDataByteSize / UInt32(MemoryLayout<Float>.size)), Int(frames))
            let copyN = min(lf, rf)
            memcpy(pcm.floatChannelData![0], ld.assumingMemoryBound(to: Float.self), copyN * MemoryLayout<Float>.size)
            memcpy(pcm.floatChannelData![1], rd.assumingMemoryBound(to: Float.self), copyN * MemoryLayout<Float>.size)
        } else if buffers.count == 1, let data = buffers[0].mData {
            // Interleaved
            let ptr = data.assumingMemoryBound(to: Float.self)
            let ch = Int(buffers[0].mNumberChannels)
            let n = min(Int(buffers[0].mDataByteSize) / (ch * MemoryLayout<Float>.size), Int(frames))
            if ch >= 2 {
                for i in 0..<n {
                    pcm.floatChannelData![0][i] = ptr[i * ch]
                    pcm.floatChannelData![1][i] = ptr[i * ch + 1]
                }
            } else {
                for i in 0..<n {
                    pcm.floatChannelData![0][i] = ptr[i]
                    pcm.floatChannelData![1][i] = ptr[i]
                }
            }
        }

        self_.callbackBox.bufferCount += 1
        self_.callbackBox.callback?(pcm)
        return noErr
    }

    // Helpers
    private func deviceName(_ id: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: CFString?
        var sz = UInt32(MemoryLayout<CFString?>.size)
        guard withUnsafeMutablePointer(to: &cf, { AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, $0) }) == noErr, let cf else { return "" }
        return cf as String
    }

    private func hasOutput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr, sz > 0 else { return false }
        let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { abl.deallocate() }
        var localSz = sz
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &localSz, abl) == noErr else { return false }
        return withUnsafePointer(to: abl.pointee.mBuffers) { UnsafeBufferPointer<AudioBuffer>(start: $0, count: Int(abl.pointee.mNumberBuffers)).reduce(0) { $0 + Int($1.mNumberChannels) } } > 0
    }
}

// MARK: - Method 2: SCStream Fallback

extension SystemAudioCapturer {

    private func startSCStream() async throws {
        let proxy = SCStreamProxy(capturer: self)
        try await proxy.start()
        scStream = proxy
    }

    private func stopSCStream() {
        scStream?.stop()
        scStream = nil
    }
}

// MARK: - SCStreamProxy (encapsulates ScreenCaptureKit capture)

@MainActor
private final class SCStreamProxy {
    private let capturer: SystemAudioCapturer
    private var stream: SCStream?

    init(capturer: SystemAudioCapturer) { self.capturer = capturer }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            capturer.captureError = "Screen Recording permission required. Open System Settings → Privacy & Security → Screen Recording."
            throw error
        }

        guard let display = content.displays.first else {
            capturer.captureError = "No display found."
            throw SystemAudioCapturer.CaptureError.deviceUnavailable
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.showsCursor = false
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5
        config.sampleRate = 48000
        config.channelCount = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        let box = capturer.callbackBox
        let fmt = capturer.engineFormat

        try s.addStreamOutput(SCAudioHandler(box: box, format: fmt), type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.audiosync.scAudio", qos: .userInteractive))
        try s.addStreamOutput(SCDummyVideo(), type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.audiosync.scVideo"))

        try await s.startCapture()
        stream = s
        DLog("[SCStream] Started")

        // 3-second sanity check
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if box.bufferCount == 0 {
                DLog("[SCStream] No buffers after 3s — permission likely missing")
                Task { @MainActor in self.capturer.captureError = "No audio captured. Grant Screen Recording permission in System Settings, then restart." }
            }
        }
    }

    func stop() {
        guard let s = stream else { return }
        Task { try? await s.stopCapture() }
        stream = nil
    }
}

// MARK: - SCStream output handlers

private final class SCAudioHandler: NSObject, SCStreamOutput {
    private let box: CallbackBox
    private let format: AVAudioFormat
    init(box: CallbackBox, format: AVAudioFormat) { self.box = box; self.format = format; super.init() }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        box.bufferCount += 1
        // Convert CMSampleBuffer → AVAudioPCMBuffer (same logic as before, compressed)
        guard let desc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let sr = asbd.pointee.mSampleRate
        let ch = asbd.pointee.mChannelsPerFrame
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let capturedFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: max(ch, 2), interleaved: false),
              let pcm = AVAudioPCMBuffer(pcmFormat: capturedFmt, frameCapacity: UInt32(frames)) else { return }

        var dataPtr: UnsafeMutablePointer<Int8>?
        var length: Int = 0
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPtr) == noErr,
              let data = dataPtr, length > 0 else { return }

        pcm.frameLength = UInt32(frames)
        let floats = data.withMemoryRebound(to: Float.self, capacity: length / MemoryLayout<Float>.size) { $0 }
        let totalFloats = length / MemoryLayout<Float>.size

        if ch >= 2 {
            for i in 0..<Int(frames) {
                let off = i * Int(ch)
                guard off + 1 < totalFloats else { break }
                pcm.floatChannelData![0][i] = floats[off]
                pcm.floatChannelData![1][i] = floats[off + 1]
            }
        } else {
            for i in 0..<Int(frames) where i < totalFloats {
                pcm.floatChannelData![0][i] = floats[i]
                pcm.floatChannelData![1][i] = floats[i]
            }
        }

        // Resample if needed
        let final = abs(sr - format.sampleRate) > 1.0 ? Self.resample(pcm, from: capturedFmt, to: format) : pcm
        if let final { box.callback?(final) }
    }

    private static func resample(_ buf: AVAudioPCMBuffer, from src: AVAudioFormat, to dst: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = dst.sampleRate / src.sampleRate
        let n = AVAudioFrameCount(Double(buf.frameLength) * ratio)
        guard n > 0, let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: n), let conv = AVAudioConverter(from: src, to: dst) else { return nil }
        out.frameLength = n
        var pos: AVAudioFramePosition = 0
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            let left = buf.frameLength - AVAudioFrameCount(pos)
            if left <= 0 { st.pointee = .endOfStream; return nil }
            pos += AVAudioFramePosition(buf.frameLength)
            st.pointee = .haveData
            return buf
        }
        return err == nil ? out : nil
    }
}

private final class SCDummyVideo: NSObject, SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

// MARK: - Errors

extension SystemAudioCapturer {
    enum CaptureError: LocalizedError {
        case deviceUnavailable
        var errorDescription: String? {
            switch self { case .deviceUnavailable: return "Audio capture device unavailable" }
        }
    }
}
