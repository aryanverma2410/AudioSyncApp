# AudioSync — Multi-Speaker Audio Router for macOS

Route **all system audio** to **multiple speakers simultaneously** with per-speaker delay, volume, EQ, and role controls. Built for syncing Bluetooth speakers with your Mac.

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
| 🎹 **Metronome** | Diagnostic click to all speakers for alignment testing |
| 📡 **Hot-Plug Detection** | Auto-detects speakers connecting/disconnecting |

---

## 📦 Installation

### Prerequisites

- macOS 13.0 or later (Ventura+)
- [BlackHole 2ch](https://existential.audio/blackhole/) — free virtual audio driver (for system audio capture)

### Step 1: Install BlackHole

BlackHole is a free, open-source virtual audio driver that lets AudioSync capture system audio without any macOS permission prompts.

```bash
brew install blackhole-2ch
```

Or download manually from [existential.audio/blackhole](https://existential.audio/blackhole/).

### Step 2: Download AudioSync

Go to **[Releases](https://github.com/aryanverma2410/AudioSyncApp/releases)** and download the latest `AudioSync.dmg`.

### Step 3: Install the App

1. Open the downloaded `.dmg` file
2. Drag **AudioSyncApp.app** to your **Applications** folder
3. **First launch:** Right-click AudioSyncApp → **Open** (required once for unsigned apps)
   - If Gatekeeper blocks it: `xattr -cr /Applications/AudioSync.app`
4. When prompted, grant **Screen Recording** permission:
   - **System Settings → Privacy & Security → Screen Recording → enable AudioSync**

### Step 4: First-Run Setup

When you open AudioSync for the first time, click **Start Setup**. The app will:
1. Verify BlackHole is installed
2. Create a Multi-Output aggregate device (routes audio to all speakers + BlackHole)
3. Set the aggregate as the system default output

Once setup is complete, click **Start** to begin routing audio.

---

## 🚀 Usage

1. **Launch AudioSync** — your speakers appear automatically
2. **Click Start** — system audio capture begins
3. **Enable/disable speakers** — toggle the switch on each speaker card
4. **Adjust per-speaker delay** — set 0ms for wired/built-in, ~200ms for Bluetooth
5. **Set per-speaker volume** — independent sliders for each speaker
6. **Apply EQ** — bass, mid, treble controls per speaker
7. **Save a Room Profile** — Profiles dropdown → Save Current as Profile…

### Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Start routing |
| ⌘. | Stop routing |
| ⇧⌘R | Refresh devices |
| ⌘1–5 | Quick-switch between first 5 profiles |

---

## 🏗️ Build from Source

```bash
git clone https://github.com/aryanverma2410/AudioSyncApp.git
cd AudioSyncApp/AudioSyncApp
swift build          # Debug build
swift run            # Build + run
```

### Open in Xcode

```bash
cd AudioSyncApp
open .swiftpm/xcode/package.xcworkspace
```

---

## ⚠️ Troubleshooting

| Issue | Solution |
|---|---|
| No audio from any speaker | Ensure the Multi-Output device is set as default in Sound settings |
| Only one speaker plays | The setup wizard should have created a Multi-Output device — re-run Setup if needed |
| App won't open (Gatekeeper) | Right-click → Open, or `xattr -cr /Applications/AudioSync.app` |
| Bluetooth speakers out of sync | Increase the delay slider for BT speakers (~200ms is typical) |
| Devices not appearing | Click **⟳ Refresh** or reconnect the device |

---

## License

MIT
