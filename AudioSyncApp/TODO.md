# TODO: AudioSyncApp

## ✅ Completed (v2.0 Rewrite)

- [x] ScreenCaptureKit-based system audio capture
- [x] Multi-device output via HAL AudioUnits with per-device delay
- [x] DelayedRingBuffer for sample-accurate per-device delay (0–500ms)
- [x] Per-device volume and mute controls
- [x] DeviceDiscovery with CoreAudio hot-plug detection
- [x] Profile persistence (JSON)
- [x] SwiftUI UI with device cards, delay sliders, volume controls
- [x] Menu bar integration
- [x] macOS 13+ target with proper framework linking

## 🔲 Remaining Work

### High Priority
- [ ] **Real-world testing** — Test with actual Bluetooth speakers, measure latency
- [ ] **Audio quality tuning** — Ring buffer sizing, lock contention, gap prevention
- [ ] **Screen Recording permission UX** — Guided permission flow with auto-detection
- [ ] **Xcode project** — Create .xcodeproj for proper code signing, entitlements, and App Sandbox

### Medium Priority
- [ ] **Audio level meters** — Per-device peak level indicators in UI
- [ ] **Auto-delay calibration** — Measure round-trip latency per device automatically
- [ ] **EQ per device** — Basic bass/treble controls
- [ ] **Keyboard shortcuts** — Global hotkeys for start/stop, profile switching
- [ ] **Window restoration** — Persist window position across launches

### Low Priority
- [ ] **AirPlay support** — Detect and route to AirPlay devices
- [ ] **Network audio** — Send audio to other Macs on the network (like real Airfoil)
- [ ] **Plugin system** — Loadable DSP effects
- [ ] **Installer/DMG** — Package as a proper macOS app bundle
