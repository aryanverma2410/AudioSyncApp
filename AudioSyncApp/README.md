# AudioSync — Open-Source Airfoil Alternative for macOS

Route **all system audio** to **multiple speakers simultaneously** — each with individual delay, volume, EQ, and role controls. Perfect for syncing Bluetooth speakers with your Mac.

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-blue" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange" />
  <img src="https://img.shields.io/github/v/release/aryanverma2410/AudioSyncApp" />
</p>

---

## ✨ Features

| Feature | Description |
|---|---|
| 🎵 **System Audio Capture** | Captures all system audio (music, videos, games, browser) |
| 🔊 **Multi-Device Output** | Route to unlimited speakers simultaneously |
| ⏱️ **Per-Speaker Delay** | 0–1000ms per device to sync Bluetooth latency |
| 🔉 **Per-Speaker Volume & Mute** | Independent controls per device |
| 🎛️ **Per-Speaker EQ** | Bass, Mid, Treble controls per speaker |
| 🔄 **Speaker Roles** | Assign Left, Right, Center, or Both per speaker |
| 👑 **Master Volume** | Single slider scales all speakers proportionally |
| 🧠 **Habit Learning** | Remembers your preferred volume/delay per speaker |
| 🎤 **Acoustic Calibration** | Uses the MacBook mic to auto-measure real speaker delays |
| 💾 **Room Profiles** | Save/switch configs (Living Room, Office, etc.) with ⌘1–5 |
| 🔧 **Auto Sync** | Measures latency and auto-compensates delays |
| 🎹 **Metronome** | Diagnostic click to all speakers for alignment testing |
| 📡 **Hot-Plug Detection** | Auto-detects speakers connecting/disconnecting |

---

## 📦 Installation

### Option 1: Download DMG (Recommended)

1. Go to **[Releases](https://github.com/aryanverma2410/AudioSyncApp/releases)**
2. Download `AudioSync.dmg`
3. Open the DMG → drag **AudioSync.app** to **Applications**
4. **First launch:** Right-click the app → **Open** (required once for unsigned apps)

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
# Install via Homebrew
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

## 🎤 Microphone Permission (For Acoustic Calibration)

The **Calibrate** feature uses your MacBook's built-in mic to measure real speaker latency. If you want to use it:

1. Open **System Settings → Privacy & Security → Microphone**
2. Enable **AudioSync**

This is **optional** — the app works fully without mic access. You only need it for the acoustic calibration feature.

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

```
┌─────────────────────────────────────────────────┐
│              System Audio Source                  │
│  (BlackHole virtual device OR ScreenCaptureKit)  │
└──────────────────┬──────────────────────────────┘
                   │ AVAudioPCMBuffer
                   ▼
┌──────────────────────────────────────────────────┐
│            MultiOutputEngine                      │
│                                                   │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐        │
│  │RingBuf  │   │RingBuf  │   │RingBuf  │        │
│  │+Delay 0 │   │+Delay   │   │+Delay   │  …     │
│  │+EQ      │   │+200ms   │   │+150ms   │        │
│  │+Role    │   │+EQ      │   │+EQ      │        │
│  └────┬────┘   └────┬────┘   └────┬────┘        │
│       ▼             ▼             ▼              │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
│  │HAL Out  │  │HAL Out  │  │HAL Out  │        │
│  │MacBook  │  │BT Spkr 1│  │BT Spkr 2│        │
│  └─────────┘  └─────────┘  └─────────┘        │
└──────────────────────────────────────────────────┘
```

---

## 🛠️ Building from Source (Developer)

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

### Open in Xcode

```bash
cd AudioSyncApp
open .swiftpm/xcode/package.xcworkspace
```

### Create a DMG Locally

```bash
brew install create-dmg
swift build -c release

# Create app bundle
mkdir -p dist/AudioSync.app/Contents/MacOS
cp .build/release/AudioSyncApp dist/AudioSync.app/Contents/MacOS/AudioSync

# Create DMG
create-dmg --volname "AudioSync" --app-drop-link 425 190 AudioSync.dmg dist/
```

---

## 🔮 Roadmap

- [ ] Code signing & notarization for frictionless install
- [ ] Real audio synchronization algorithms (drift correction)
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
| App won't open (Gatekeeper) | Right-click → Open, or `xattr -cr /Applications/AudioSync.app` |
| Devices not appearing | Click **⟳ Refresh** or reconnect the device |

---

## License

MIT
