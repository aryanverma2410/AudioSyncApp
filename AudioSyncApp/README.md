<div align="center">

# 🎵 AudioSync

### Open-Source Airfoil Alternative for macOS

Route **all system audio** to **multiple speakers simultaneously** — each with individual delay, volume, EQ, and role controls. Perfect for syncing Bluetooth speakers with your Mac.

<p>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?style=for-the-badge" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=for-the-badge" />
  <img src="https://img.shields.io/github/v/release/aryanverma2410/AudioSyncApp?style=for-the-badge&label=LATEST%20RELEASE" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge" />
</p>

<p>
  <a href="https://github.com/aryanverma2410/AudioSyncApp/releases/latest">
    <img src="https://img.shields.io/badge/⬇%20DOWNLOAD-DMG%20(v1.3)-success?style=for-the-badge&logo=apple" />
  </a>
</p>

---

</div>

## 📸 Screenshots

<div align="center">

```
┌─────────────────────────────────────────────────────────────┐
│  🎵 AudioSync                                    [● Start]  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  🔊 ZEB-DUKE PLUS                          Connected ✓      │
│  ├─ Delay:  ████████░░░░░░░  186ms                         │
│  ├─ Volume: ██████████████  100%                           │
│  ├─ EQ:     Bass ████░░  Mid ██████  Treb ██░░░░             │
│  └─ Role:   [ Both ]  [ Left ]  [ Right ]  [ Center ]       │
│                                                             │
│  🔊 ZEB-PODS 141 R                          Connected ✓      │
│  ├─ Delay:  ████░░░░░░░░░░  72ms                           │
│  ├─ Volume: ██████████████  100%                            │
│  ├─ EQ:     Bass ████░░  Mid ██████  Treb ██░░░░            │
│  └─ Role:   [ Both ]  [ Left ]  [ Right ]  [ Center ]       │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  👑 Master Volume: ████████████░  85%                      │
│  📡 Auto Sync  ·  🎤 Calibrate  ·  💾 Profiles  ·  🎹 Test  │
└─────────────────────────────────────────────────────────────┘
```

</div>

---

## ✨ Features

### 🎯 Core Audio Routing

| Feature | Description |
|---|---|
| 🎵 **System Audio Capture** | Captures all system audio — music, videos, games, browsers — via BlackHole or ScreenCaptureKit |
| 🔊 **Multi-Device Output** | Route to unlimited speakers simultaneously — Bluetooth, USB, Built-in |
| ⏱️ **Per-Speaker Delay** | 0–1000ms per device to sync Bluetooth latency |
| 🔉 **Per-Speaker Volume & Mute** | Independent controls per device |
| 🎛️ **Per-Speaker EQ** | Bass, Mid, Treble controls per speaker |
| 🔄 **Speaker Roles** | Assign Left, Right, Center, or Both per speaker |

### 🧠 Intelligent Sync

| Feature | Description |
|---|---|
| 🧠 **Habit Learning** | Remembers your preferred volume/delay per speaker — reconnects with saved settings |
| 🎤 **Acoustic Calibration** | Uses the MacBook mic to auto-measure real speaker delays |
| 🔧 **Auto Sync** | Measures latency and auto-compensates delays across all speakers |
| 🎹 **Metronome** | Diagnostic click to all speakers for manual alignment testing |
| 📡 **Hot-Plug Detection** | Auto-detects speakers connecting/disconnecting mid-session |

### 🎛️ Advanced Controls

| Feature | Description |
|---|---|
| 👑 **Master Volume** | Single slider scales all speakers proportionally |
| 💾 **Room Profiles** | Save/switch configs (Living Room, Office, etc.) with ⌘1–5 |
| 📊 **Live Diagnostics** | Per-device buffer distance, drift, and delay monitoring |
| ⌨️ **Global Hotkeys** | Control routing without switching apps |

---

## 📦 Installation

### Option 1: Download DMG (Recommended)

> **[⬇ Download AudioSync v1.3 DMG](https://github.com/aryanverma2410/AudioSyncApp/releases/latest)**

1. Download `AudioSync.dmg` from the link above or **[Releases](https://github.com/aryanverma2410/AudioSyncApp/releases)**
2. Open the DMG → drag **AudioSyncApp.app** to **Applications**
3. **Install BlackHole 2ch** (free, required for audio capture): `brew install blackhole-2ch`
4. **First launch:** Right-click AudioSyncApp → **Open** (required once for unsigned apps)
5. Click **Start Setup** in the app — auto-configures BlackHole routing
6. Grant **Screen Recording** permission when prompted

### Option 2: Build from Source

```bash
git clone https://github.com/aryanverma2410/AudioSyncApp.git
cd AudioSyncApp/AudioSyncApp
swift build -c release
.build/release/AudioSyncApp
```

---

## 🔧 Setup Guide (First Time)

AudioSync needs a way to capture your Mac's system audio. There are **two methods** — Method 1 is recommended (no permissions dialog):

### Method 1: BlackHole (Recommended — No Permission Prompt)

[BlackHole](https://existential.audio/blackhole/) is a free, open-source virtual audio driver. It lets AudioSync capture system audio silently without any macOS permission dialogs.

#### Step 1: Install BlackHole

```bash
brew install blackhole-2ch
```

Or download from [existential.audio/blackhole](https://existential.audio/blackhole/).

#### Step 2: Create a Multi-Output Device

This sends audio to **both** your speakers AND BlackHole simultaneously:

1. Open **Audio MIDI Setup** (search Spotlight for "Audio MIDI Setup")
2. Click the **⊕** button (bottom-left) → **Create Multi-Output Device**
3. **Check** ☑️ all your speakers (MacBook Speakers, Bluetooth speakers, etc.)
4. **Check** ☑️ **BlackHole 2ch**
5. Rename it to something like **"AudioSync Multi-Output"**

```
┌─────────────────────────────────────────────────┐
│  Audio MIDI Setup — Multi-Output Device          │
│                                                   │
│  ☑️ MacBook Speakers                              │
│  ☑️ ZEB-DUKE PLUS (Bluetooth)                     │
│  ☑️ ZEB-PODS 141 R (Bluetooth)                    │
│  ☑️ BlackHole 2ch                                │
│  ☐ Other unused devices...                        │
│                                                   │
│  Master Device: MacBook Speakers                  │
│  Drift Correction: ✓ (enabled for master)         │
└─────────────────────────────────────────────────┘
```

#### Step 3: Set the Multi-Output as Default

1. Open **System Settings → Sound → Output**
2. Select **"AudioSync Multi-Output"** as the output device
   - Or in Audio MIDI Setup: right-click → **Use This Device for Sound Output**

#### Step 4: Launch AudioSync

1. Open AudioSync
2. Click **Start** — it auto-detects BlackHole and captures via it (no permission popups!)
3. Adjust per-speaker delay, volume, EQ as needed

> **Tip:** If you don't create a Multi-Output device, you'll hear audio from only one speaker. The Multi-Output Device is what fans the audio out to all speakers simultaneously.

### Method 2: ScreenCaptureKit (Fallback — Needs Permission)

If you don't install BlackHole, AudioSync falls back to Apple's ScreenCaptureKit. This works but requires:

1. **Screen Recording permission** — When prompted, click **Allow**
2. Open **System Settings → Privacy & Security → Screen Recording**
3. Enable **AudioSync** in the list

> ⚠️ With this method, you must also set your Mac's output to a **Multi-Output Device** (same as Step 2 above) for multi-speaker output.

---

## 🚀 Usage

1. **Launch AudioSync** — Your speakers appear automatically
2. **Click Start** — System audio capture begins
3. **Adjust per-speaker delay** — Set 0ms for wired/Built-in, ~200ms for Bluetooth
4. **Fine-tune with Auto Sync** — Click the **Auto Sync** button to auto-measure and compensate latency
5. **Use Acoustic Calibration** — Click **Calibrate** for mic-based measurement (experimental)
6. **Save a Room Profile** — Click the **Profiles** dropdown → **Save Current as Profile…**

### Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Start routing |
| ⌘. | Stop routing |
| ⇧⌘R | Refresh devices |
| ⌘1–5 | Quick-switch between first 5 profiles |

---

## 🏗️ Architecture

<div align="center">

```
┌──────────────────────────────────────────────────────────────┐
│                     SYSTEM AUDIO SOURCE                       │
│              (BlackHole virtual device OR SCStream)            │
└──────────────────────────┬───────────────────────────────────┘
                           │ AVAudioPCMBuffer
                           ▼
┌──────────────────────────────────────────────────────────────┐
│                    MultiOutputEngine                           │
│                                                                │
│   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐      │
│   │ RingBuffer 1  │   │ RingBuffer 2  │   │ RingBuffer 3  │     │
│   │ ───────────  │   │ ───────────  │   │ ───────────  │      │
│   │ Delay: 0ms   │   │ Delay: 200ms │   │ Delay: 150ms │      │
│   │ Volume: 100% │   │ Volume: 85%  │   │ Volume: 90%  │      │
│   │ EQ: Flat     │   │ EQ: Bass+3dB │   │ EQ: Flat     │      │
│   │ Role: Both   │   │ Role: Left   │   │ Role: Right  │      │
│   └──────┬───────┘   └──────┬───────┘   └──────┬───────┘      │
│          ▼                  ▼                  ▼               │
│   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐      │
│   │  HAL Output  │   │  HAL Output  │   │  HAL Output  │      │
│   │  Unit #1     │   │  Unit #2     │   │  Unit #3     │      │
│   │  Built-in    │   │  BT Speaker  │   │  BT Speaker  │      │
│   └──────────────┘   └──────────────┘   └──────────────┘      │
│                                                                │
│   ┌─────────────────────────────────────────────────────────┐ │
│   │  RingBufferSnapshot (lock-free read, no audio-thread    │ │
│   │  allocation — os_unfair_lock guarded snapshot)          │ │
│   └─────────────────────────────────────────────────────────┘ │
│                                                                │
│   ┌─────────────────────────────────────────────────────────┐ │
│   │  Drift Correction Engine                                 │ │
│   │  • Tolerance band: ±1 callback (~512 frames)             │ │
│   │  • Proportional nudge: drift/64, capped at 256 samples   │ │
│   │  • Direction: too-close → repeat, too-far → skip         │ │
│   │  • OSMemoryBarrier after setDelay (ARM64 store ordering) │ │
│   └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

</div>

### Key Design Decisions

| Component | Approach | Why |
|---|---|---|
| **Audio Capture** | BlackHole (primary) / ScreenCaptureKit (fallback) | BlackHole avoids permission dialogs |
| **Ring Buffers** | Per-device `DelayedRingBuffer` with 10.9s capacity | Absorbs Bluetooth jitter + enables per-device delay |
| **Thread Safety** | `RingBufferSnapshot` with `os_unfair_lock` | Zero allocation on audio thread |
| **Drift Correction** | Proportional nudge toward target distance | Corrects BT clock drift without audible clicks |
| **Device Output** | HAL Output Units via `AudioComponentFindNext` | Direct hardware access, lowest latency |
| **State Management** | `@Published` + `ObservableObject` (SwiftUI) | Live UI updates from CoreAudio listeners |

---

## 🔧 Building from Source (Developer)

### Prerequisites

- macOS 13.0+ (Ventura or later)
- Xcode 15+ or Swift 5.9+
- [BlackHole 2ch](https://existential.audio/blackhole/) (recommended)

### Build & Run

```bash
cd AudioSyncApp
swift build                  # Debug build
swift build -c release       # Release build
swift run                    # Build + run
```

### Run Tests

```bash
cd AudioSyncApp
swift test                    # XCTest suite
swift Tests/DelayedRingBufferTests.swift  # Ring buffer unit tests (12 tests)
```

### Open in Xcode

```bash
cd AudioSyncApp
open .swiftpm/xcode/package.xcworkspace
```

### Create a DMG Locally

```bash
cd AudioSyncApp
bash build_app.sh             # Build + create .app bundle + codesign
```

---

## 📋 What's New

### v1.3 — Drift Correction Fix + Enhanced Diagnostics

**Fixed:** 5–10 second delay accumulation on certain Bluetooth speakers (ZEB-PODS 141 R)

**Root cause:** Drift correction directions were **reversed**. Both branches pushed `readPos` *away* from target distance instead of *toward* it. The proportional nudge (up to 256 samples/callback) amplified drift 64× faster than the old ±1/callback approach.

| Bug | Symptom | Fix |
|---|---|---|
| Drift direction reversed | 5–10s delay on ZEB-PODS, not on other speakers | Corrected: too-close → `rp -= nudge` (repeat), too-far → `rp += nudge` (skip) |
| setDelay + reversed drift | Static/crackling noise immediately after changing delay | Fixed by correcting drift direction — no more discontinuity |
| Delay "keeps changing" | Drift correction fighting user-set delay | Tolerance band (±1 callback) prevents nudging in steady state |

**Added:**
- Per-device diagnostics: `dist` (buffer distance), `drift` (deviation from target), `delayMs` per device
- `currentDelayMs` computed property on `DelayedRingBuffer`
- 4 new ring buffer unit tests (12 total, all passing)

### v1.2 — Audio Engine Overhaul

- Ring buffer snapshot (zero audio-thread allocation via `os_unfair_lock`)
- `OSMemoryBarrier()` after `setDelay` for ARM64 store ordering
- CPU overload guard removed (was causing false silences)
- `volumeLookup` default 1.0 (was 0 = silence during device add/remove)
- `injectTestTone` writes to all ring buffers (was desyncing write positions)
- 12 ring buffer unit tests

### v1.1 — Features

- Per-speaker EQ (Bass/Treble/Mid)
- Speaker roles (Left/Right/Center)
- Room profiles with persistence
- Habit learning for volume/delay
- Acoustic calibration via mic
- Master volume control
- Metronome with per-speaker output

---

## 📊 Diagnostics

AudioSync logs per-device diagnostics every 2 seconds:

```
diag: captureBufs=54530 capturePeak=0.3402 devices=2
diag: 'ZEB-DUKE PLUS' writes=45002 reads=41344 vol=1.00 dist=24576 drift=0 delayMs=186.0
diag: 'ZEB-PODS 141 R' writes=33749 reads=30869 vol=1.00 dist=23552 drift=-128 delayMs=72.0
```

| Field | Meaning |
|---|---|
| `captureBufs` | Total audio buffers received from BlackHole/SCStream |
| `capturePeak` | Peak audio level (0.0 = silence, 1.0 = full scale) |
| `writes` / `reads` | Write/read call counts (not positions) |
| `dist` | Current `writePos - readPos` (actual buffer fill in frames) |
| `drift` | `dist - targetDistance` (positive = too far, negative = too close) |
| `delayMs` | User-set delay in milliseconds |

**Log location:** `~/Library/Logs/AudioSyncApp.log`

---

## 🔮 Roadmap

- [ ] Code signing & notarization for frictionless install
- [x] Drift correction algorithms (v1.3)
- [ ] Virtual audio driver (eliminate BlackHole dependency)
- [ ] Network audio (send to other Macs, like real Airfoil)
- [ ] DSP effects (compression, loudness normalization)
- [ ] Apple Silicon native optimizations

---

## ⚠️ Troubleshooting

| Issue | Solution |
|---|---|
| No audio from any speaker | Ensure a **Multi-Output Device** is set as system default in Sound settings |
| Only one speaker plays | Create a Multi-Output Device in Audio MIDI Setup with all speakers checked |
| Screen Recording permission loop | Install BlackHole (Method 1) to bypass SCStream entirely |
| Bluetooth speakers out of sync | Use **Auto Sync** or **Calibrate** to measure and compensate delays |
| One speaker 5-10s behind others | Update to v1.3 — drift correction direction bug fixed |
| Static noise after setting delay | Update to v1.3 — reversed drift correction caused discontinuity |
| Delay keeps changing | Update to v1.3 — tolerance band prevents steady-state nudging |
| App won't open (Gatekeeper) | Right-click → Open, or `xattr -cr /Applications/AudioSync.app` |
| Devices not appearing | Click **⟳ Refresh** or reconnect the device |

---

## 📝 License

MIT

---

<div align="center">

**Built with** 🎵 **SwiftUI + AVFoundation + CoreAudio on macOS**

[Report Bug](https://github.com/aryanverma2410/AudioSyncApp/issues) ·
[Request Feature](https://github.com/aryanverma2410/AudioSyncApp/issues) ·
[Releases](https://github.com/aryanverma2410/AudioSyncApp/releases)

</div>
