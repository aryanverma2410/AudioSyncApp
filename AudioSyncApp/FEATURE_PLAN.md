# Feature Implementation Plan — 12 Features + 2 Design Docs

## Phase 1: Audio DSP (MultiOutputEngine.swift + new AudioDSP.swift)

### 1. Mono Mode
- Global toggle like AudioMode. When active, downmix L+R to (L+R)/2 in HAL render callback.
- File-scope `_monoMode = AtomicFloat(0)` flag.
- Applied before volume/EQ in render callback.

### 2. Subwoofer Crossover
- Per-device toggle + crossover frequency (default 80Hz).
- Low-pass filter in render callback for devices marked as subwoofer.
- 2nd-order Butterworth LPF at selectable freq (60/80/100/120Hz).
- Store in DeviceSettings: `isSubwoofer: Bool, crossoverHz: Float`.

### 3. Audio Compressor/Limiter
- Global toggle. Simple dynamics processor in render callback.
- Threshold (-20dB to 0dB), ratio (2:1 to 10:1), attack/release.
- Prevents clipping and volume spikes. Especially for party/karaoke.
- New `Compressor` class with envelope follower.

### 4. Reverb/Ambience Presets
- Global toggle with presets: None, Room, Hall, Stadium, Cathedral.
- Schroeder reverberator: 4 comb filters + 2 allpass filters.
- Applied globally (before per-device volume).
- New `Reverb` class with preset configs.

## Phase 2: Engine Stability (MultiOutputEngine.swift)

### 5. Auto-Retry HAL Failure
- In `startSafely()`, retry each HAL unit start up to 3× with 500ms delay.
- Log each retry attempt.

### 6. End-to-End Latency Meter
- Stamp buffers with `mach_absolute_time()` at capture.
- In HAL render callback, compute elapsed time → display per device.
- Store in `_latencyLookup` (ThreadSafeLookup<String, Float>).

### 7. Health Dashboard Data
- Track: underrun count, drift amount, callback gaps per device.
- New `DeviceHealth` struct: underrunCount, avgDrift, lastUnderrunTime.
- Exposed via `healthReport(for:) -> DeviceHealth`.

## Phase 3: State & Lifecycle (AppState.swift + AppDelegate.swift)

### 8. Sleep Timer
- `@Published var sleepTimerMinutes: Int?` and countdown.
- Timer fires `stop()` when elapsed.
- UI: Menu with 15/30/45/60/90/custom/Off.

### 9. Auto-Start at Login
- Already has `ServiceManagement` imported in AppDelegate.
- Wire `SMAppService.mainApp.register()` / unregister.
- Persist preference in UserDefaults.

### 10. Profile Auto-Switch by Network
- Monitor WiFi SSID changes via `CoreWLAN` (`CWWiFiClient`).
- Map SSID → profile name in UserDefaults.
- When SSID changes, auto-load mapped profile.

### 11. Global Hotkeys
- Carbon `RegisterEventHotKey` for:
  - ⌘⇧K: Toggle karaoke
  - ⌘⇧M: Toggle mute all
  - ⌘⇧S: Start/Stop routing
  - ⌘⇧Space: Toggle sleep timer
- Registered in AppDelegate.

## Phase 4: UI (ContentView.swift + new files)

### 12. Mini Floating Widget
- New `MiniWidgetPanel.swift`: NSPanel, always-on-top, compact.
- Shows: Start/Stop, Master Vol, Audio Mode, Sleep Timer.
- Toggle button in main window toolbar to show/hide.
- Persists visibility preference.

### 13. Health Dashboard
- New `HealthDashboardView.swift`: Overlay or sheet.
- Per-device: buffer fill %, underrun count, drift frames, latency ms.
- Color-coded: green/yellow/red status.
- Accessible from toolbar.

### 14. Latency Meter Display
- Per-device latency shown in device card (small "Xms" label).
- Updated by VU timer (already runs at 20Hz).

## Phase 5: Design Docs (no implementation)

### 15. Guest Queue Mode — Design Doc
### 16. Multi-Host Sync — Design Doc

## Implementation Order
1. Phase 1+2 (DSP + engine stability) — single subagent, MultiOutputEngine focus
2. Phase 3 (state + lifecycle) — subagent, AppState + AppDelegate focus  
3. Phase 4 (UI) — subagent, ContentView + new files
4. Phase 5 (design docs) — direct write
5. Build + verify after each phase
