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
private let kSafetyFrames: Int = 8192

// Minimal reimplementation of DelayedRingBuffer for testing.
// This mirrors the exact setDelay/read logic from MultiOutputEngine.swift.
// If the source changes, update this copy.

final class TestRingBuffer {
    private let buffer: UnsafeMutablePointer<Float>
    private let frameCount: Int
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
// 500ms at 48kHz = 24000 frames; safety = 8192; total = 32192. Write 32768.
let testWriteFrames: AVAudioFrameCount = 32768

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

// MARK: - Summary

print("\n" + String(repeating: "=", count: 50))
print("Results: \(passed) passed, \(failed) failed, \(passed + failed) total")
if failed > 0 {
    print("❌ SOME TESTS FAILED")
    exit(1)
} else {
    print("✅ ALL TESTS PASSED")
}
