# AudioSyncApp — Airfoil Alternative for macOS

An open-source Airfoil alternative that captures **all system audio** and routes it to **multiple output devices simultaneously** (MacBook speakers + Bluetooth speakers + any audio output), each with **individually adjustable delay** to compensate for Bluetooth latency differences.

## Features

- 🎵 **System Audio Capture** — Captures all system audio via ScreenCaptureKit (music, videos, games, browser)
- 🔊 **Multi-Device Output** — Route audio to 3+ devices simultaneously (MacBook speakers + 2 BT speakers)
- ⏱️ **Per-Speaker Delay** — Individual delay control (0–500ms) per device to sync Bluetooth speakers
- 🔉 **Per-Speaker Volume** — Independent volume and mute controls per device
- 💾 **Profiles** — Save and load device delay/volume configurations
- 🔄 **Hot-Plug Detection** — Automatically detects Bluetooth speakers connecting/disconnecting
- 📊 **Live Status** — Real-time device count, engine state, CPU usage

## Architecture

```
┌─────────────────────────────────────────────┐
│           SystemAudioCapturer               │
│    (ScreenCaptureKit SCStream + audio)       │
│         ↓ AVAudioPCMBuffer                  │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│           MultiOutputEngine                 │
│                                             │
│  ┌──────────┐   ┌──────────────────┐       │
│  │ Player   │→  │ MainMixerNode    │       │
│  │ Node     │   │ (tap installed)  │       │
│  └──────────┘   └────────┬─────────┘       │
│                          │                  │
│              ┌───────────┼───────────┐      │
│              ▼           ▼           ▼      │
│         ┌────────┐  ┌────────┐  ┌────────┐ │
│         │RingBuf │  │RingBuf │  │RingBuf │ │
│         │+Delay  │  │+Delay  │  │+Delay  │ │
│         │0ms     │  │200ms   │  │150ms   │ │
│         └───┬────┘  └───┬────┘  └───┬────┘ │
│             ▼           ▼           ▼      │
│         ┌────────┐  ┌────────┐  ┌────────┐ │
│         │HAL Out │  │HAL Out │  │HAL Out │ │
│         │MacBook │  │BT Spkr1│  │BT Spkr2│ │
│         └────────┘  └────────┘  └────────┘ │
└─────────────────────────────────────────────┘
```

**Key Components:**
- **SystemAudioCapturer**: Uses `SCStream` with `capturesAudio=true` to capture system audio
- **MultiOutputEngine**: Fan-out architecture with per-device `DelayedRingBuffer` + HAL output unit
- **DeviceDiscovery**: CoreAudio device enumeration with hot-plug listener
- **ProfileManager**: JSON-based persistence for device settings

## Requirements

- macOS 13.0+ (Ventura or later)
- Xcode 15+ (for building)
- Screen Recording permission (System Settings → Privacy & Security → Screen Recording)

## Building

```bash
cd AudioSyncApp
swift build
```

Or open in Xcode:
```bash
open .swiftpm/xcode/package.xcworkspace
```

## Running

```bash
swift run AudioSyncApp
```

On first launch, grant **Screen Recording** permission when prompted. This is required by ScreenCaptureKit to capture system audio.

## Usage

1. **Launch the app** — Your MacBook speakers and any connected Bluetooth devices appear automatically
2. **Click "Start Routing"** — System audio capture begins
3. **Adjust delays** — Set 0ms for MacBook speakers, ~200ms for Bluetooth speakers
4. **Fine-tune** — Use the delay presets (0ms, 150ms, 200ms, 300ms) for quick calibration
5. **Save a profile** — Click "+" in the sidebar to save your current settings

## Project Structure

```
Sources/AudioSyncApp/
├── App.swift                  # SwiftUI entry point + menu commands
├── AppDelegate.swift          # Menu bar icon, routing notifications
├── AppState.swift             # Central coordinator
├── ContentView.swift          # Main UI: device cards + controls
├── Models.swift               # AudioOutputDevice, DeviceSettings, AudioProfile
├── DeviceDiscovery.swift       # CoreAudio device enumeration + hot-plug
├── SystemAudioCapturer.swift   # ScreenCaptureKit audio capture
├── MultiOutputEngine.swift     # Fan-out to N HAL output units with delay
├── ProfileManager.swift        # JSON persistence for profiles
├── ProfileView.swift           # Profile management UI
└── SettingsView.swift          # Preferences + diagnostics
```

## License

MIT
