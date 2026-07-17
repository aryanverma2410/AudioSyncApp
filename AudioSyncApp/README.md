# Audio Sync Application

A professional macOS application for synchronizing audio playback across multiple output devices with precise latency compensation.

## Features

- **Multi-Device Audio Output**: Play audio simultaneously through multiple output devices
- **Per-Device Latency Compensation**: Independent delay adjustment (-1000ms to +1000ms) for perfect synchronization
- **Independent Volume Control**: Individual volume, mute, and solo controls for each device
- **Global Controls**: Master volume, play/pause, stop, and synchronization controls
- **Profile Management**: Save and load different device configurations for various environments
- **Device Discovery**: Automatic detection of CoreAudio-compatible devices (built-in, Bluetooth, USB, AirPlay, HDMI)
- **Low Latency Performance**: Optimized for <20ms latency (excluding hardware delays)
- **Modern macOS Interface**: Built with SwiftUI following Apple's design guidelines

## System Requirements

- macOS 14.0 or later
- 64-bit Intel or Apple Silicon Mac

## Installation

1. Clone or download this repository
2. Open `AudioSyncApp.xcodeproj` in Xcode
3. Select your development team in the signing settings
4. Build and run the application

## Usage

### Device Setup
1. Launch the application
2. The app will automatically detect available audio output devices
3. Select the devices you want to use for audio playback
4. Use the delay sliders to synchronize audio output between devices
5. Adjust individual volumes as needed

### Creating Profiles
1. Configure your devices with desired volume and delay settings
2. Click the "+" button in the profiles sidebar
3. Enter a name for your profile (e.g., "Living Room", "Office")
4. Click the checkmark to save

### Using Profiles
1. Select a profile from the sidebar to apply its settings
2. Click the play button to start audio playback
3. Adjust settings in real-time while audio is playing

## Architecture

The application follows a modular architecture:

- **AudioEngine**: Core audio processing and playback engine using CoreAudio
- **DeviceManager**: Discovers and monitors audio input/output devices
- **ProfileManager**: Handles saving and loading of user configurations
- **UI Layer**: Built with SwiftUI for a modern, responsive interface

## Audio Processing

The audio engine uses:
- CoreAudio for low-latency audio input/output
- Custom buffer management for synchronization
- Sample-accurate timing for precise sample alignment
- Dynamic latency compensation for Bluetooth and network devices

## Development

### Project Structure
```
AudioSyncApp/
├── Sources/
│   └── AudioSyncApp/
│       ├── Models.swift          # Data models and protocols
│       ├── AudioEngine.swift     # Core audio processing
│       ├── DeviceManager.swift   # Device discovery and monitoring
│       ├── ProfileManager.swift  # Profile persistence
│       ├── Views/                # SwiftUI views
│       └── App.swift             # App entry point
├── AudioSyncAppTests/            # Unit tests
└── Resources/                    # Asset catalog, etc.
```

### Dependencies
This project uses only Apple's built-in frameworks:
- SwiftUI
- CoreAudio
- AudioToolbox
- AVFoundation
- CoreBluetooth (for Bluetooth device battery monitoring)

## License

This project is licensed under the MIT License - see the LICENSE file for details.