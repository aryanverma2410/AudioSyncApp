# STATE — AudioSyncApp BT Crackling Fix

## Goal
Eliminate static/crackling on Bluetooth speakers while maintaining simultaneous multi-speaker output.

## Now
Root cause analysis complete. Three causes identified. About to implement fixes.

## Next
Implement: (1) pre-allocated IOProc buffer, (2) independent read tracking per ring buffer, (3) increase safety frames for BT

## Root Causes

### RC1: AVAudioPCMBuffer malloc on IOProc (SystemAudioCapturer.swift:219)
Every IOProc callback allocates a new AVAudioPCMBuffer. Heap malloc on audio thread causes timing jitter. On BT's longer IO period, jitter becomes audible crackles.
**Fix:** Pre-allocate reusableBuffer in CallbackBox, memcpy into it in IOProc.

### RC2: Read position tied to write position (DelayedRingBuffer:128)
`readStart = max(wp - totalDist, 0)` — read position is computed from write position. Writer runs at 48kHz. Reader (BT at 44.1kHz) consumes fewer frames per time unit. The divergence means:
- Writes accumulate faster than reads can consume
- Gap grows linearly (~10.9% for 44.1kHz BT)
- After enough time, the read wraps around the ring buffer and catches stale/already-overwritten data
**Fix:** Independent _readPos that the reader advances itself. No derivation from _writePos.

### RC3: Safety margin too low for BT (DelayedRingBuffer:73)
`safetyFrames = 1024` (~21ms at 48kHz). BT's codec latency can be 100-200ms. When the BT HAL unit's render callback is delayed by codec encoding, 21ms isn't enough safety → underrun → pop.
**Fix:** Increase safetyFrames to ~4096 (~85ms) as baseline. For BT, this provides enough buffer.

## Constraints
- Must not break working audio on wired/Built-in speakers
- Must not add perceptible latency (>300ms total is noticeable)
- Must work like Airfoil (system audio to all speakers)
- Pre-allocated buffer approach only — no new abstractions

## Failed Attempts
- ATTEMPT 1 [L1]: Zero-allocation rawCallback via CallbackBox.rawCallback → rawCallback was nil at IOProc time (captureBufs=0, writes=0). Likely MainActor isolation prevented nonisolated IOProc from seeing the property.
- ATTEMPT 2 [L1]: writeRaw + distributeAudioDirectRaw → same nil-callback issue + added unnecessary methods to MultiOutputEngine.
