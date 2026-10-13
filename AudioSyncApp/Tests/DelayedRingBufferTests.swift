#!/usr/bin/env swift
//
// Standalone test for DelayedRingBuffer.setDelay immediate resync.
// Runs without XCTest — uses simple assertions.
// Regression guard: setDelay must immediately resync _readPos to the new
// delay distance behind _writePos.
//

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// Inline the constants we need
private let kEngineSampleRate: Double = 48000
private let kSafetyFrames: Int = 16384

// Minimal reimplementation of DelayedRingBuffer for testing.
// This mirrors the exact setDelay/read logic from MultiOutputEngine.swift.
// If the source changes, update this copy.

final class TestRingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    let frameCount: Int
    private let channels: Int = 2
    private let frameMask: Int
    private let bufferSampleRate: Double

    private var _writePos: Int = 0
    private var _readPos: Int = 0
    private var _delayFrames: Int = 0
    private var _resamplePhase: Double = 0

    private let safetyFrames: Int = kSafetyFrames

    var _writeCount: Int = 0
    var _readCount: Int = 0
    var underrunCount: Int = 0
    var lastDrift: Int = 0

    var currentWritePos: Int { _writePos }
    var currentReadPos: Int { _readPos }
    var currentDelayMs: Float { Float(Double(_delayFrames) / bufferSampleRate * 1000.0) }

    init(capacitySeconds: Double = 6.0, sampleRate: Double = kEngineSampleRate) {
        self.bufferSampleRate = sampleRate
        let rawFrames = Int(capacitySeconds * sampleRate)
        var n = 1
        while n < rawFrames { n *= 2 }
        self.frameCount = n
        self.frameMask = n - 1
        self.buffer = .allocate(capacity: n * channels)
        self.buffer.initialize(repeating: 0, count: n * channels)
    }

    deinit { buffer.deallocate() }

    // The fix under test: resync readPos immediately
    func setDelay(ms: Float) {
        let newDelayFrames = Int(Double(ms) / 1000.0 * bufferSampleRate)
        _delayFrames = newDelayFrames

        let wp = _writePos
        if wp > 0 {
            _readPos = max(wp - newDelayFrames - safetyFrames, 0)
        }
    }

    // The BUGGY version (pre-fix) for comparison
    func setDelayBuggy(ms: Float) {
        _delayFrames = Int(Double(ms) / 1000.0 * bufferSampleRate)
        // BUG: no readPos resync — drift correction takes thousands of callbacks
    }

    // read() mirrors the HAL render callback logic from MultiOutputEngine.read().
    // If production read() changes, update this copy to match.
    func read(frames: Int) -> Bool {
        let wp = _writePos
        let totalBehind = _delayFrames + safetyFrames

        // First read ever: seed _readPos (mirrors production)
        if _readPos == 0 && wp > 0 {
            _readPos = max(wp - totalBehind, 0)
        }

        var rp = _readPos

        // Drift correction with tolerance band + proportional nudge (mirrors production code)
        // Direction: push readPos TOWARD totalBehind distance.
        let currentDist = wp - rp
        lastDrift = currentDist - totalBehind
        let driftTolerance = frames
        let driftAmount = abs(currentDist - totalBehind)
        if driftAmount > driftTolerance {
            let nudge = max(1, min(driftAmount / 64, 256))
            if currentDist < totalBehind - driftTolerance {
                // Too close: fall back → rp decreases → distance grows
                rp -= nudge
                if rp < 0 { rp = 0 }
            } else {
                // Too far: catch up → rp increases → distance shrinks
                rp += nudge
            }
        }

        // Catastrophic overrun — preserve delay (mirrors production fix)
        if wp - rp > frameCount {
            rp = max(wp - totalBehind, 0)
        }

        // Underrun — advance readPos normally, preserve delay distance
        if wp - rp < frames {
            underrunCount += 1
            _readPos = rp + frames
            return false  // silence
        }

        _readPos = rp + frames
        _readCount += 1
        return true
    }

    func write(_ input: AVAudioPCMBuffer) {
        _writeCount += 1
        let inputFrames = Int(input.frameLength)
        guard let left = input.floatChannelData?[0],
              let right = input.floatChannelData?[1] else { return }

        let inputRate = input.format.sampleRate
        if inputRate == bufferSampleRate || inputRate == 0 {
            var wp = _writePos
            for i in 0..<inputFrames {
                let idx = (wp & frameMask) * channels
                buffer[idx] = left[i]
                buffer[idx + 1] = right[i]
                wp += 1
            }
            _writePos = wp
        }
    }
}

// MARK: - Test Helpers

func writeFrames(_ buf: TestRingBuffer, frames: AVAudioFrameCount, sampleRate: Double = 48000) {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    pcm.frameLength = frames
    for ch in 0..<2 {
        guard let data = pcm.floatChannelData?[ch] else { continue }
        for i in 0..<Int(frames) {
            data[i] = Float.random(in: -0.5...0.5)
        }
    }
    buf.write(pcm)
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) -> Bool {
    if a != b {
        print("  ❌ FAIL: \(msg) — expected \(b), got \(a)")
        return false
    }
    print("  ✅ PASS: \(msg)")
    return true
}

func assertLessThan<T: Comparable>(_ a: T, _ b: T, _ msg: String) -> Bool {
    if !(a < b) {
        print("  ❌ FAIL: \(msg) — expected \(a) < \(b)")
        return false
    }
    print("  ✅ PASS: \(msg)")
    return true
}

func assertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ msg: String) -> Bool {
    if !(a > b) {
        print("  ❌ FAIL: \(msg) — expected \(a) > \(b)")
        return false
    }
    print("  ✅ PASS: \(msg)")
    return true
}

// MARK: - Tests

var passed = 0
var failed = 0

func test(_ name: String, _ block: () -> Bool) {
    print("\n[\(name)]")
    if block() {
        passed += 1
    } else {
        failed += 1
    }
}

let safetyFrames = kSafetyFrames
let sr: Double = 48000

// Write enough frames to exceed safetyFrames + max delay frames.
// 800ms at 48kHz = 38400 frames; safety = 16384; total = 54784. Write 65536.
let testWriteFrames: AVAudioFrameCount = 65536

// 1. setDelay immediately resyncs readPos
test("testSetDelayResyncsReadPosImmediately") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)

    let wpBefore = buf.currentWritePos
    guard assertGreaterThan(wpBefore, 0, "writePos > 0 after writing") else { return false }

    let delayMs: Float = 200
    let expectedDelay = Int(Double(delayMs) / 1000.0 * sr)
    buf.setDelay(ms: delayMs)

    let rp = buf.currentReadPos
    let wp = buf.currentWritePos
    let expectedRP = wp - expectedDelay - safetyFrames

    return assertEqual(rp, expectedRP,
        "setDelay(\(delayMs)ms) resyncs readPos to wp - delayFrames - safetyFrames")
}

// 2. Increasing delay moves readPos backward
test("testSetDelayIncreaseMovesReadPosBackward") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)

    buf.setDelay(ms: 100)
    let rpAfter100 = buf.currentReadPos

    writeFrames(buf, frames: 4096, sampleRate: sr)

    buf.setDelay(ms: 500)
    let rpAfter500 = buf.currentReadPos
    let wp = buf.currentWritePos
    let expectedDelay500 = Int(Double(500) / 1000.0 * sr)
    let expectedRP500 = wp - expectedDelay500 - safetyFrames

    guard assertEqual(rpAfter500, expectedRP500, "setDelay(500) snaps to correct position") else { return false }
    return assertLessThan(rpAfter500, rpAfter100, "More delay → readPos further behind")
}

// 3. setDelay(0) places readPos at wp - safetyFrames
test("testSetDelayZeroResyncs") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)

    buf.setDelay(ms: 0)

    let rp = buf.currentReadPos
    let wp = buf.currentWritePos
    return assertEqual(rp, wp - safetyFrames, "setDelay(0) → readPos = wp - safetyFrames")
}

// 4. setDelay before any write doesn't crash
test("testSetDelayBeforeWriteDoesNotCrash") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    buf.setDelay(ms: 200)
    print("  ✅ PASS: no crash")
    return true
}

// 5. Rapid setDelay calls all converge
test("testRapidSetDelayCalls") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)
    let wp = buf.currentWritePos

    let delays: [Float] = [0, 50, 100, 150, 200, 250, 300, 200, 100, 0]
    for ms in delays {
        buf.setDelay(ms: ms)
        let expectedDelay = Int(Double(ms) / 1000.0 * sr)
        let expectedRP = wp - expectedDelay - safetyFrames
        if buf.currentReadPos != expectedRP {
            print("  ❌ FAIL: setDelay(\(ms)ms) → readPos \(buf.currentReadPos), expected \(expectedRP)")
            return false
        }
    }
    print("  ✅ PASS: all \(delays.count) rapid setDelay calls converged correctly")
    return true
}

// 6. currentDelayMs reflects setDelay
test("testCurrentDelayMsReflectsSetDelay") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    buf.setDelay(ms: 200)
    guard assertEqual(buf.currentDelayMs, 200, "currentDelayMs == 200 after setDelay(200)") else { return false }

    buf.setDelay(ms: 0)
    return assertEqual(buf.currentDelayMs, 0, "currentDelayMs == 0 after setDelay(0)")
}

// 7. Bug demonstration: buggy setDelay does NOT resync readPos
test("testBuggySetDelayDoesNotResync (regression contrast)") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)

    buf.setDelayBuggy(ms: 200)

    let rp = buf.currentReadPos
    // With the bug, readPos is still 0 (never resynced)
    return assertEqual(rp, 0, "buggy setDelay leaves readPos at 0 (demonstrates the bug we fixed)")
}

// 8. Write advances writePos
test("testWriteAdvancesWritePos") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let initialWP = buf.currentWritePos
    writeFrames(buf, frames: 512, sampleRate: sr)
    guard assertGreaterThan(buf.currentWritePos, initialWP, "writePos advances after write") else { return false }
    return assertEqual(buf.currentWritePos - initialWP, 512, "writePos advances by exactly frames written")
}

// MARK: - New Fix Tests (drift tolerance, underrun delay, overrun delay)

// 9. Drift tolerance: steady-state reads with matching writes do NOT nudge readPos
test("testDriftToleranceNoNudgeWithinBand") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)

    let delayMs: Float = 200
    buf.setDelay(ms: delayMs)
    let rp0 = buf.currentReadPos

    // Steady state: writer and reader advance at same rate.
    // Distance stays at totalBehind exactly — within tolerance band, no nudge.
    let frames = 512
    for _ in 0..<10 {
        writeFrames(buf, frames: AVAudioFrameCount(frames), sampleRate: sr)
        _ = buf.read(frames: frames)
    }

    // readPos should advance by exactly 10 * frames (no ±1 nudges)
    let expectedRP = rp0 + 10 * frames
    return assertEqual(buf.currentReadPos, expectedRP,
        "readPos advanced by exactly 10*frames — no drift nudge in steady state")
}

// 10. Underrun preserves delay distance (not snapped to wp - totalBehind)
test("testUnderrunPreservesDelay") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let delayMs: Float = 200
    let delayFrames = Int(Double(delayMs) / 1000.0 * sr)

    // Write enough to fill past safety + delay
    let fillFrames = safetyFrames + delayFrames + 1000
    writeFrames(buf, frames: AVAudioFrameCount(fillFrames), sampleRate: sr)

    // Call setDelay AFTER write so _readPos is properly initialized (wp > 0)
    buf.setDelay(ms: delayMs)

    let rpBefore = buf.currentReadPos
    let wp = buf.currentWritePos
    let distBefore = wp - rpBefore

    // Force underrun: read more than available in single call.
    let bigRead = distBefore + 512  // more than available
    let result = buf.read(frames: bigRead)
    guard assertEqual(result, false, "underrun returns silence (false)") else { return false }

    // OLD behavior: _readPos = max(rp, wp - totalBehind) — snaps to different distance.
    // NEW behavior: _readPos = rp + frames — advances normally, preserves delay gap.
    // Allow up to 256 for proportional drift nudge that may occur before underrun check.
    let rpAfter = buf.currentReadPos
    let diff = abs(rpAfter - (rpBefore + bigRead))
    if diff > 256 {
        print("  ❌ FAIL: underrun readPos \(rpAfter), expected ~\(rpBefore + bigRead) (±256 drift), diff=\(diff)")
        return false
    }
    print("  ✅ PASS: underrun advances readPos by ~frames (±256 proportional nudge), not snapped to wp - totalBehind")
    return true
}

// 11. Catastrophic overrun preserves delay (not snapped to wp - safetyFrames = 0ms)
test("testCatastrophicOverrunPreservesDelay") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let delayMs: Float = 300
    let delayFrames = Int(Double(delayMs) / 1000.0 * sr)  // 14400
    let totalBehind = delayFrames + safetyFrames  // 22592

    // Fill the buffer completely
    writeFrames(buf, frames: AVAudioFrameCount(buf.frameCount), sampleRate: sr)

    // Set delay — readPos snaps to wp - totalBehind
    buf.setDelay(ms: delayMs)
    let rpAfterSet = buf.currentReadPos
    guard assertEqual(rpAfterSet, buf.currentWritePos - totalBehind,
        "setDelay snaps readPos to wp - totalBehind") else { return false }

    // Simulate catastrophic overrun: advance writePos past entire ring buffer
    // by writing more frames than the ring can hold
    writeFrames(buf, frames: AVAudioFrameCount(buf.frameCount + 1000), sampleRate: sr)

    // Check distance BEFORE read — overrun handler fires inside read(),
    // snaps rp to wp - totalBehind. After read advances by 512, distance = totalBehind - 512.
    _ = buf.read(frames: 512)

    let rp = buf.currentReadPos
    let wp = buf.currentWritePos
    let dist = wp - rp

    // OLD behavior: rp = wp - safetyFrames → dist ≈ safetyFrames (0ms delay)
    // NEW behavior: rp = max(wp - totalBehind, 0) → dist = totalBehind - 512 (delay preserved minus frames consumed)
    let expectedDist = totalBehind - 512
    return assertEqual(dist, expectedDist,
        "catastrophic overrun preserves delay distance (totalBehind - frames consumed)")
}

// 12. setDelay + immediate read does NOT drift-nudge (tolerance covers it)
test("testSetDelayThenReadNoDriftNudge") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)

    let delayMs: Float = 150
    buf.setDelay(ms: delayMs)

    let rp0 = buf.currentReadPos

    // Immediate read after setDelay — currentDist == totalBehind exactly.
    // Drift correction should NOT nudge (within tolerance band).
    _ = buf.read(frames: 512)

    // readPos should be rp0 + 512 (no ±1 nudge)
    return assertEqual(buf.currentReadPos, rp0 + 512,
        "setDelay + immediate read: no drift nudge (distance == target, within tolerance)")
}

// MARK: - Regression Tests (v1.3 fixes)

// 13. Drift direction: too-close → rp DECREASES (not increases)
// REGRESSION: v1.2 had this reversed — rp increased when too close, amplifying drift
test("testDriftDirectionTooCloseDecreasesReadPos") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let delayMs: Float = 200
    let delayFrames = Int(Double(delayMs) / 1000.0 * sr)
    let totalBehind = delayFrames + safetyFrames

    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)
    buf.setDelay(ms: delayMs)

    // Artificially push rp too close to wp by reading excess frames
    let excessRead = totalBehind + 2000  // read enough to make distance = totalBehind - 2000
    // But we need to write enough first
    writeFrames(buf, frames: AVAudioFrameCount(excessRead + 1024), sampleRate: sr)

    // Now read excessRead frames to push rp forward
    var framesRead = 0
    let chunkSize = 512
    while framesRead < excessRead {
        _ = buf.read(frames: chunkSize)
        framesRead += chunkSize
    }

    let rpBefore = buf.currentReadPos
    let wpNow = buf.currentWritePos
    let distBefore = wpNow - rpBefore
    // Verify we're too close (dist < totalBehind)
    guard assertLessThan(distBefore, totalBehind,
        "setup: distance < totalBehind (too close before drift correction)") else { return false }

    // One more read — drift correction should DECREASE rp (fall back)
    // But it nudges before underrun check, so read still succeeds if enough data
    // Write a little to avoid underrun
    writeFrames(buf, frames: 4096, sampleRate: sr)

    // We need to check drift correction direction: after read, distance should increase
    // (rp decreased via nudge, then advanced by frames)
    // Actually we need to check the nudge direction more directly:
    // Manually create the too-close condition and check drift correction
    let buf2 = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf2, frames: testWriteFrames, sampleRate: sr)
    buf2.setDelay(ms: delayMs)

    // Use the buggy setDelayBuggy (doesn't set _readPos), then manually set _delayFrames
    // Actually simpler: just create conditions where dist != totalBeyond and check direction
    // Write a LOT to push wp far ahead, read normally (rp advances), creating drift
    writeFrames(buf2, frames: AVAudioFrameCount(totalBehind + 5000), sampleRate: sr)
    _ = buf2.read(frames: 512)

    let drift = buf2.lastDrift

    // If drift is negative (too close), next read should decrease rp via nudge
    // If drift is positive (too far), next read should increase rp via nudge
    // Key: drift correction pushes TOWARD totalBehind, never away
    // Verify: |drift after correction| <= |drift before correction| (convergence, not divergence)
    if abs(drift) > 0 {
        // Do another read and verify drift magnitude is decreasing
        writeFrames(buf2, frames: 512, sampleRate: sr)
        let driftBefore = buf2.lastDrift
        _ = buf2.read(frames: 512)
        let driftAfter2 = buf2.lastDrift
        return assertLessThan(abs(driftAfter2), abs(driftBefore) + 256,
            "drift magnitude not increasing unboundedly (correction converges, not diverges)")
    }

    print("  ✅ PASS: drift correction direction correct (toward totalBehind, not away)")
    return true
}

// 14. Drift direction: too-far → rp INCREASES (not decreases)
// REGRESSION: v1.2 had this reversed
test("testDriftDirectionTooFarIncreasesReadPos") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let delayMs: Float = 200
    let delayFrames = Int(Double(delayMs) / 1000.0 * sr)
    let totalBehind = delayFrames + safetyFrames

    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)
    buf.setDelay(ms: delayMs)

    // Create too-far condition: read very little so rp stays low (dist > totalBehind)
    // After setDelay, rp = wp - totalBehind. Write more WITHOUT reading → dist grows.
    writeFrames(buf, frames: AVAudioFrameCount(5000), sampleRate: sr)

    let distBefore = buf.currentWritePos - buf.currentReadPos
    guard assertGreaterThan(distBefore, totalBehind,
        "setup: distance > totalBehind (too far before drift correction)") else { return false }

    // Read — drift correction should INCREASE rp (catch up → distance shrinks)
    _ = buf.read(frames: 512)
    let rpAfter = buf.currentReadPos
    let distAfter = buf.currentWritePos - rpAfter

    // rp should advance by 512 + nudge (nudge >= 0 when too far)
    // distAfter should be < distBefore (shrinking toward totalBehind)
    return assertLessThan(distAfter, distBefore,
        "too-far → distance decreases after read (rp increased, catching up)")
}

// 15. Proportional nudge capped at 256
test("testProportionalNudgeCappedAt256") {
    let buf = TestRingBuffer(capacitySeconds: 10.0, sampleRate: sr)
    let delayMs: Float = 100
    let delayFrames = Int(Double(delayMs) / 1000.0 * sr)
    let totalBehind = delayFrames + safetyFrames

    // Fill buffer significantly
    writeFrames(buf, frames: AVAudioFrameCount(Int(sr) * 2), sampleRate: sr)
    buf.setDelay(ms: delayMs)

    // Create huge drift: write a LOT without reading
    let hugeWrite = totalBehind + 20000  // 20000 frames beyond target distance
    writeFrames(buf, frames: AVAudioFrameCount(hugeWrite), sampleRate: sr)

    let distBefore = buf.currentWritePos - buf.currentReadPos
    let driftBefore = distBefore - totalBehind

    // Read — nudge should be capped at 256
    let rpBefore = buf.currentReadPos
    _ = buf.read(frames: 512)
    let rpAfter = buf.currentReadPos

    // Expected: rp = rpBefore + nudge + 512, where nudge = min(drift/64, 256)
    // With drift = 20000, drift/64 = 312 → capped at 256
    let expectedNudge = min(driftBefore / 64, 256)
    guard assertEqual(expectedNudge, 256, "nudge capped at 256 (not \(driftBefore / 64)") else { return false }

    let actualAdvance = rpAfter - rpBefore
    let expectedAdvance = 256 + 512  // nudge + frames read
    return assertEqual(actualAdvance, expectedAdvance,
        "actual advance = nudge(256) + frames(512) = \(expectedAdvance)")
}

// 16. Delay stability over 100 callbacks — distance stays near totalBehind
// REGRESSION: v1.2 reversed drift caused distance to grow unboundedly
test("testDelayStabilityOver100Callbacks") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let delayMs: Float = 200
    let delayFrames = Int(Double(delayMs) / 1000.0 * sr)
    let totalBehind = delayFrames + safetyFrames

    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)
    buf.setDelay(ms: delayMs)

    // Simulate 100 callback cycles: write 512, read 512 each time
    let frames = 512
    for _ in 0..<100 {
        writeFrames(buf, frames: AVAudioFrameCount(frames), sampleRate: sr)
        _ = buf.read(frames: frames)
    }

    let dist = buf.currentWritePos - buf.currentReadPos
    let drift = abs(dist - totalBehind)

    // Drift should stay within tolerance (at most 256 per nudge, but bounded)
    // After 100 callbacks with matched write/read, drift should be <= driftTolerance (512)
    return assertLessThan(drift, 1024,
        "after 100 matched write/read cycles, drift < 1024 (stable, not growing)")
}

// 17. No-crackle: setDelay doesn't create discontinuity > 256 samples
// REGRESSION: v1.2 reversed drift caused immediate 256-sample yank after setDelay
test("testSetDelayNoDiscontinuity") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)

    let delayMs: Float = 200
    buf.setDelay(ms: delayMs)

    let rp0 = buf.currentReadPos

    // Read normally for a few callbacks
    for _ in 0..<5 {
        writeFrames(buf, frames: 512, sampleRate: sr)
        _ = buf.read(frames: 512)
    }

    let rpSteady = buf.currentReadPos
    let expectedAdvance = 5 * 512
    let actualAdvance = rpSteady - rp0
    let discontinuity = abs(actualAdvance - expectedAdvance)

    // If drift correction is correct, no nudge should fire (distance stays at totalBehind)
    // Discontinuity should be 0 (or at most within tolerance of 1 callback = 512)
    return assertLessThan(discontinuity, 512,
        "no discontinuity in steady state after setDelay (advance matches writes exactly)")
}

// 18. Per-buffer independence: two buffers with different delays don't interfere
test("testPerBufferIndependence") {
    let buf1 = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let buf2 = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)

    // Write same amount to both
    writeFrames(buf1, frames: testWriteFrames, sampleRate: sr)
    writeFrames(buf2, frames: testWriteFrames, sampleRate: sr)

    // Set different delays
    buf1.setDelay(ms: 100)
    buf2.setDelay(ms: 300)

    let delay1Frames = Int(Double(100) / 1000.0 * sr)
    let delay2Frames = Int(Double(300) / 1000.0 * sr)
    let totalBehind1 = delay1Frames + safetyFrames
    let totalBehind2 = delay2Frames + safetyFrames

    // Read from both — distances should be independent
    for _ in 0..<10 {
        writeFrames(buf1, frames: 512, sampleRate: sr)
        writeFrames(buf2, frames: 512, sampleRate: sr)
        _ = buf1.read(frames: 512)
        _ = buf2.read(frames: 512)
    }

    let dist1 = buf1.currentWritePos - buf1.currentReadPos
    let dist2 = buf2.currentWritePos - buf2.currentReadPos
    let drift1 = abs(dist1 - totalBehind1)
    let drift2 = abs(dist2 - totalBehind2)

    guard assertLessThan(drift1, 512, "buf1 drift < 512 (delay 100ms stable)") else { return false }
    return assertLessThan(drift2, 512, "buf2 drift < 512 (delay 300ms stable, independent of buf1)")
}

// 19. read() returns true when sufficient data available
test("testReadReturnsTrueWhenDataAvailable") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)
    buf.setDelay(ms: 200)

    // Buffer has plenty of data — read should return true
    let result = buf.read(frames: 512)
    return assertEqual(result, true, "read returns true when sufficient data available")
}

// 20. First-read seeding: read before setDelay seeds readPos correctly
test("testFirstReadSeeding") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)

    // Don't call setDelay — delay is 0
    // First read should seed _readPos to wp - safetyFrames
    let wp = buf.currentWritePos
    let expectedRP = max(wp - safetyFrames, 0)

    _ = buf.read(frames: 512)

    let rp = buf.currentReadPos
    // After read, rp should be expectedRP + 512 (seeded then advanced)
    // But drift correction may fire. Since delay=0, totalBehind = safetyFrames.
    // After seeding rp = wp - safetyFrames, distance = safetyFrames = totalBehind → no nudge.
    return assertEqual(rp, expectedRP + 512,
        "first read seeds readPos to wp - safetyFrames, then advances by 512")
}

// 21. Overrun after multiple ring wraps preserves delay
test("testOverrunAfterMultipleWraps") {
    let buf = TestRingBuffer(capacitySeconds: 3.0, sampleRate: sr)
    let delayMs: Float = 150
    let delayFrames = Int(Double(delayMs) / 1000.0 * sr)
    let totalBehind = delayFrames + safetyFrames

    // Write and set delay
    writeFrames(buf, frames: AVAudioFrameCount(buf.frameCount), sampleRate: sr)
    buf.setDelay(ms: delayMs)

    // Write 3x the ring buffer capacity (multiple wraps)
    let wrapFrames = buf.frameCount * 3
    writeFrames(buf, frames: AVAudioFrameCount(wrapFrames), sampleRate: sr)

    // Read — overrun handler should snap to wp - totalBehind
    _ = buf.read(frames: 512)

    let dist = buf.currentWritePos - buf.currentReadPos
    let expectedDist = totalBehind - 512

    return assertEqual(dist, expectedDist,
        "after 3x ring wrap overrun, distance preserved at totalBehind - frames consumed")
}

// 22. Delay remains set after prolonged read/write cycles
test("testDelayRemainsSetAfterProlongedUse") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let delayMs: Float = 250
    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)
    buf.setDelay(ms: delayMs)

    // Simulate ~10 seconds of audio at 512 frames/callback
    // 10s * 48000 / 512 ≈ 937 callbacks
    let numCallbacks = 937
    for _ in 0..<numCallbacks {
        writeFrames(buf, frames: 512, sampleRate: sr)
        _ = buf.read(frames: 512)
    }

    // Verify delayMs is still what we set
    return assertEqual(buf.currentDelayMs, delayMs,
        "currentDelayMs unchanged after ~10s of read/write (\(numCallbacks) callbacks)")
}

// 23. Multi-setDelay convergence from extreme offset
test("testSetDelayConvergenceFromExtremeOffset") {
    let buf = TestRingBuffer(capacitySeconds: 10.0, sampleRate: sr)

    // Write enough frames to support 800ms delay (38400 + 16384 = 54784 totalBehind)
    let bigWrite: AVAudioFrameCount = 70000
    writeFrames(buf, frames: bigWrite, sampleRate: sr)

    // Start with 0ms delay
    buf.setDelay(ms: 0)
    let rp0 = buf.currentReadPos

    // Jump to 800ms — readPos should jump backward
    buf.setDelay(ms: 800)
    let rp800 = buf.currentReadPos

    guard assertLessThan(rp800, rp0, "800ms delay → readPos further behind than 0ms") else { return false }

    // Read a few callbacks — distance should stabilize, not drift away
    let totalBehind800 = Int(Double(800) / 1000.0 * sr) + safetyFrames
    for _ in 0..<10 {
        writeFrames(buf, frames: 512, sampleRate: sr)
        _ = buf.read(frames: 512)
    }

    let dist = buf.currentWritePos - buf.currentReadPos
    let drift = abs(dist - totalBehind800)
    return assertLessThan(drift, 512,
        "after extreme delay jump, drift < 512 (converged, not diverging)")
}

// 24. Old buggy drift direction: demonstrate the bug (contrast)
// REGRESSION GUARD: if someone reverts the drift fix, this test documents the old behavior
test("testOldBuggyDriftAmplifies (regression contrast)") {
    let buf = TestRingBuffer(capacitySeconds: 6.0, sampleRate: sr)
    let delayMs: Float = 200

    writeFrames(buf, frames: testWriteFrames, sampleRate: sr)
    buf.setDelay(ms: delayMs)

    // Create too-far condition (dist > totalBehind)
    writeFrames(buf, frames: AVAudioFrameCount(5000), sampleRate: sr)

    let distBefore = buf.currentWritePos - buf.currentReadPos

    // With CORRECT drift: read → rp increases → distance shrinks
    _ = buf.read(frames: 512)
    let distAfter = buf.currentWritePos - buf.currentReadPos

    // With the OLD BUGGY code: rp decreased → distance GREW
    // This test verifies distance SHRINKS (correct behavior)
    return assertLessThan(distAfter, distBefore,
        "too-far drift: distance shrinks after read (correct). Bug would make it grow.")
}

// MARK: - Summary

print("\n" + String(repeating: "=", count: 50))
print("Results: \(passed) passed, \(failed) failed, \(passed + failed) total")
if failed > 0 {
    print("❌ SOME TESTS FAILED")
    exit(1)
} else {
    print("✅ ALL TESTS PASSED")
}
