import XCTest
@testable import AudioSyncApp

/// Tests for DelayedRingBuffer delay resync behavior.
///
/// Regression guard: setDelay() must immediately resync _readPos to the new
/// delay distance behind _writePos. Without this, the ±1-sample gradual drift
/// correction takes thousands of callbacks to converge — the delay slider felt
/// non-responsive (a 200ms change took ~200 callbacks at 512 frames to apply).
final class DelayedRingBufferTests: XCTestCase {

    // MARK: - Helpers

    private func writeFrames(_ buffer: DelayedRingBuffer, frames: AVAudioFrameCount, sampleRate: Double = 48000) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        pcmBuffer.frameLength = frames
        for ch in 0..<2 {
            guard let channelData = pcmBuffer.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frames) {
                channelData[i] = Float.random(in: -0.5...0.5)
            }
        }
        buffer.write(pcmBuffer)
    }

    // MARK: - setDelay Immediate Resync

    /// After writing data, setDelay must immediately snap readPos to
    /// writePos - delayFrames - safetyFrames.
    func testSetDelayResyncsReadPosImmediately() {
        let sampleRate: Double = 48000
        let buffer = DelayedRingBuffer(capacitySeconds: 6.0, sampleRate: sampleRate)

        // Write a substantial amount of data so writePos is well ahead
        writeFrames(buffer, frames: 4096, sampleRate: sampleRate)

        let wpBefore = buffer.currentWritePos
        XCTAssertGreaterThan(wpBefore, 0, "writePos should be > 0 after writing data")

        // Set a 200ms delay
        let delayMs: Float = 200
        let expectedDelayFrames = Int(Double(delayMs) / 1000.0 * sampleRate)
        buffer.setDelay(ms: delayMs)

        let rp = buffer.currentReadPos
        let wp = buffer.currentWritePos

        // Read pos should be exactly wp - delayFrames - safetyFrames
        // (safetyFrames = 8192 per kSafetyFrames)
        let safetyFrames = 8192
        let expectedReadPos = wp - expectedDelayFrames - safetyFrames

        XCTAssertEqual(rp, expectedReadPos,
                       "setDelay must immediately resync readPos. Expected \(expectedReadPos), got \(rp). " +
                       "If this fails, the delay slider won't respond until drift correction converges.")
    }

    /// Changing delay from 100ms to 500ms should immediately update readPos.
    func testSetDelayChangeUpdatesReadPos() {
        let sampleRate: Double = 48000
        let buffer = DelayedRingBuffer(capacitySeconds: 6.0, sampleRate: sampleRate)

        writeFrames(buffer, frames: 4096, sampleRate: sampleRate)

        // Set initial 100ms delay
        buffer.setDelay(ms: 100)
        let rpAfter100 = buffer.currentReadPos

        // Write more data
        writeFrames(buffer, frames: 2048, sampleRate: sampleRate)

        // Change to 500ms — should jump readPos backward immediately
        buffer.setDelay(ms: 500)
        let rpAfter500 = buffer.currentReadPos
        let wp = buffer.currentWritePos

        let expectedDelay500 = Int(Double(500) / 1000.0 * sampleRate)
        let safetyFrames = 8192
        let expectedReadPos500 = wp - expectedDelay500 - safetyFrames

        XCTAssertEqual(rpAfter500, expectedReadPos500,
                       "setDelay(500) must immediately snap readPos to new delay distance.")

        // ReadPos should have moved backward (more delay = further behind writer)
        XCTAssertLessThan(rpAfter500, rpAfter100,
                          "Increasing delay should move readPos further behind writePos.")
    }

    /// setDelay(0) should place readPos at writePos - safetyFrames.
    func testSetDelayZeroResyncs() {
        let sampleRate: Double = 48000
        let buffer = DelayedRingBuffer(capacitySeconds: 6.0, sampleRate: sampleRate)

        writeFrames(buffer, frames: 2048, sampleRate: sampleRate)

        buffer.setDelay(ms: 0)

        let rp = buffer.currentReadPos
        let wp = buffer.currentWritePos
        let safetyFrames = 8192

        XCTAssertEqual(rp, wp - safetyFrames,
                       "setDelay(0) should place readPos at wp - safetyFrames.")
    }

    /// Calling setDelay before any data is written should not crash
    /// (writePos = 0, so resync is skipped via the `if wp > 0` guard).
    func testSetDelayBeforeWriteDoesNotCrash() {
        let buffer = DelayedRingBuffer(capacitySeconds: 6.0, sampleRate: 48000)
        buffer.setDelay(ms: 200)
        // No crash = success
    }

    /// Multiple rapid setDelay calls should all converge correctly.
    func testRapidSetDelayCalls() {
        let sampleRate: Double = 48000
        let buffer = DelayedRingBuffer(capacitySeconds: 6.0, sampleRate: sampleRate)
        let safetyFrames = 8192

        writeFrames(buffer, frames: 4096, sampleRate: sampleRate)
        let wp = buffer.currentWritePos

        // Rapid-fire changes simulating slider drag
        let delays: [Float] = [0, 50, 100, 150, 200, 250, 300, 200, 100, 0]
        for ms in delays {
            buffer.setDelay(ms: ms)
            let expectedDelay = Int(Double(ms) / 1000.0 * sampleRate)
            let expectedRP = wp - expectedDelay - safetyFrames
            XCTAssertEqual(buffer.currentReadPos, expectedRP,
                           "setDelay(\(ms)ms) did not immediately resync readPos")
        }
    }

    // MARK: - Current Delay Property

    func testCurrentDelayMsReflectsSetDelay() {
        let buffer = DelayedRingBuffer(capacitySeconds: 6.0, sampleRate: 48000)

        buffer.setDelay(ms: 200)
        XCTAssertEqual(buffer.currentDelayMs, 200, accuracy: 1.0,
                       "currentDelayMs should reflect the last setDelay value")

        buffer.setDelay(ms: 0)
        XCTAssertEqual(buffer.currentDelayMs, 0, accuracy: 1.0,
                       "currentDelayMs should be ~0 after setDelay(0)")
    }

    // MARK: - Read/Write Basic

    func testWriteAdvancesWritePos() {
        let buffer = DelayedRingBuffer(capacitySeconds: 6.0, sampleRate: 48000)
        let initialWP = buffer.currentWritePos

        writeFrames(buffer, frames: 512, sampleRate: 48000)

        XCTAssertGreaterThan(buffer.currentWritePos, initialWP,
                             "writePos should advance after writing data")
        XCTAssertEqual(buffer.currentWritePos - initialWP, 512,
                       "writePos should advance by exactly the number of frames written")
    }

    func testWriteCountIncrements() {
        let buffer = DelayedRingBuffer(capacitySeconds: 1.0, sampleRate: 48000)
        XCTAssertEqual(buffer._writeCount, 0)

        writeFrames(buffer, frames: 256, sampleRate: 48000)
        XCTAssertEqual(buffer._writeCount, 1)

        writeFrames(buffer, frames: 256, sampleRate: 48000)
        XCTAssertEqual(buffer._writeCount, 2)
    }
}
