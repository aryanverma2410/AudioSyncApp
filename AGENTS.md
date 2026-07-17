# AGENTS.md — Anti Workspace

## Project Overview

Anti is a **macOS audio routing and synchronization workspace** containing multiple Swift/SwiftUI applications and a Python automation utility. The central theme is multi-device Bluetooth/audio management — discovering audio devices, routing audio streams, synchronizing playback across speakers, and compensating for latency/drift.

The workspace is organized as several semi-independent sub-projects that share similar architecture and CoreAudio/AVFoundation patterns but are built and run separately.

## Architecture & Components

| Directory | Description | Build System |
|---|---|---|
| `MyHomeTheatreApp.swift` | Standalone single-file SwiftUI app (root level). Combines DeviceManager, AudioEngine, and ContentView in one file. Bluetooth speaker discovery + per-device delay sliders. | Xcode (single-file) |
| `AudioSyncApp/` | Full-featured macOS menu-bar app. Modular SPM package with separate targets for app UI, audio engine, device manager, and profile persistence. Targets macOS 14+. | Swift Package Manager (`swift build/test`) |
| `AirFoilRouter/` | Airfoil-style system audio capture and multi-device delay routing. Uses ScreenCaptureKit (`SCStream`) to tap system audio and route buffers to output devices. Two sub-targets: `AirfoilAudioRouter` (tap engine) and `AirFoilRouter` (router + speaker UI). | Xcode project |
| `BlueSync/` | Two iterations (v1, v2) of a Bluetooth audio sync app. Template-generated Xcode projects. | Xcode project |
| `Sources/` | Root-level shared source modules (`Audio/`, `Device/`, `UI/`) used by root-level builds. | SPM or manual |
| `Tests/` | Root-level test target (`DeviceManagerTests.swift`). | XCTest |
| `workflow_automation/` | Python Selenium script automating Samsung VPN login + SmartDSI portal navigation. | pip |

## Key Technologies

- **Swift / SwiftUI** — All app UIs
- **AVFoundation / AVAudioEngine** — Audio playback, mixing, and scheduling
- **CoreAudio / AudioToolbox** — Low-level device enumeration, HAL output units, transport-type filtering
- **ScreenCaptureKit** — System-wide audio tap (in AirFoilRouter)
- **Combine** — Reactive bindings in DeviceManager
- **Python 3 + Selenium** — Browser automation (workflow_automation)

## Building and Running

### AudioSyncApp (SPM)
```bash
cd AudioSyncApp
swift build                  # Build
swift test                   # Run tests (AudioSyncAppTests)
open .swiftpm/xcode/package.xcworkspace  # Open in Xcode
```

### Xcode Projects (AirFoilRouter, BlueSync)
Open the respective `.xcodeproj` in Xcode. Build and run via the standard Xcode workflow (⌘R / ⌘B).

### Workflow Automation
```bash
cd workflow_automation
pip install -r requirements.txt   # selenium, webdriver-manager
python vpn_vdi_automation.py      # Requires Chrome + updated credentials
```

### Root-Level Sources
The root `Sources/` and `Tests/` directories are structured for SPM consumption but do not have a root `Package.swift`. They are intended to be integrated into an SPM package or Xcode project as needed.

## Development Conventions

### Swift Style
- **Singletons** for shared managers: `DeviceManager.shared`, `AudioEngine.shared`
- **`@Published` + `ObservableObject`** for SwiftUI state injection
- **`EnvironmentObject`** propagation from the App entry point (see `AudioSyncApp/App.swift`)
- **CoreAudio property listeners** registered in `init()` for live device updates
- **Mock injection pattern**: `DeviceManager.mockDevices` static property allows tests to override device lists without hitting real CoreAudio
- `// MARK: -` section comments for organizing code regions

### Audio Engine Patterns
- `AVAudioEngine` graph: `PlayerNode → MixerNode/DelayNode → OutputNode`
- Per-device delay via `AVAudioUnitDelay` keyed by device UID
- HAL output units created via `AudioComponentFindNext` / `AudioUnitSetProperty` for routing to specific audio devices
- Level metering via `installTap(onBus:)` on mixer nodes with `vDSP_maxv` peak detection

### Testing
- XCTest targets alongside each app
- Mock data injection via static `mockDevices` property on DeviceManager
- `DeviceManagerTests.swift` at root demonstrates the mock pattern for Bluetooth filtering

### Python (workflow_automation)
- Selenium WebDriver with Chrome profile reuse (`--user-data-dir`)
- Resilient selector strategies: tries multiple CSS selectors/XPath expressions per UI element
- Comprehensive `logging` module usage (file + console)
- Timeout-based polling loops for async states (SSO, VPN connection)

## Important Notes

- **`settings.json`** contains environment configuration including API keys. Never commit secrets or log them.
- Several sub-projects appear to be iterative prototypes exploring the same audio-sync problem from different angles (MyHomeTheatreApp → AudioSyncApp → AirFoilRouter → BlueSync).
- The `AudioSyncApp/TODO.md` tracks planned features: virtual audio driver integration, real synchronization algorithms, DSP effects, and packaging.
- `DeviceManager.swift` at root has a known syntax issue (duplicate code block after the `static var mockDevices` line) — the `refreshDevices()` method body appears twice.
