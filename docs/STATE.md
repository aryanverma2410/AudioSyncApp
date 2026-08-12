# STATE — Anti Workspace

## Goal
Multi-project workspace: AudioSyncApp (macOS audio router) + Superhuman-Agent (AI desktop control agent) + AudioTranslateCLI (offline audio translation).

## Session: AudioTranslateCLI Full Audit + Polish + Tests + Feature

### What Changed
- **audio_translate_cli.py** (UPDATED):
  - Removed dead `MULTILINGUAL_VOSK_MODELS` constant (defined, never used)
  - Added `try/except ImportError` guards for `vosk` and `argostranslate` — missing packages now print helpful install instructions instead of raw ImportError tracebacks
  - Added `from typing import Optional` and replaced all `str | None` with `Optional[str]` for Python 3.9 compatibility (test environment runs 3.9.6)
  - Added live progress display: elapsed time + segment count on stderr using `\r` (zero new deps, zero new flags)
  - Added `flush=True` to partial results print (consistency with progress display)
  - `list_languages()` now handles `argostranslate is None` gracefully
- **tests/conftest.py** (NEW): Injects mock `vosk` and `argostranslate` modules into `sys.modules` so tests run without the real heavyweight ML packages
- **tests/test_audio_translate_cli.py** (NEW): 15 pytest tests covering TTSWorker (enqueue/stop/daemon/espeak-missing), load_translation (no packages/no match/match/auto-detect), CLI args (--list-langs/no-input/invalid-lang/nonexistent-file), and LANGUAGES constant integrity
- **.gitignore** (NEW): Ignores `__pycache__/`, `*.pyc`, `venv/`, `.venv/`, `models/`, `*.egg-info/`, `.pytest_cache/`
- **README.md** (REWRITTEN): Synced with actual code — documents 14 supported languages, all CLI flags (`--target-lang`, `--source-lang`, `--chunk-size`, `--no-partials`, `--list-langs`), test instructions, troubleshooting table. Removed stale references to non-existent `speak_hindi` function and "Hindi only" language.

### Verification
- `python3 -m pytest tests/ -v` → **15 passed in 0.01s** (Verified)
- Syntax check: `python3 -c "import ast; ast.parse(open('audio_translate_cli.py').read())"` → SYNTAX OK (Verified)

### Known Issues
- Tests use mock modules — cannot test actual Vosk/Argos/eSpeak integration without real models + binaries installed
- Python 3.9 compatibility required `Optional[str]` instead of `str | None` (3.10+ syntax); if upgrading to 3.10+ minimum, can revert to `str | None`


## Now
Superhuman-agent: All 82 tests pass. Phases 1-8 complete (T001-T045). Core system fully implemented:
- Kernel-level input injection (CGEvent) via `mac_input.py`
- Accessibility tree scraping (AXUIElement) via `mac_accessibility.py`
- Parallel perception-execution pipeline with frame differencing
- Local VLM engine with stub backend (swap for real vLLM/TensorRT)
- Prompt system with compressed JSON schema enforcement
- Agent loop with accessibility-first decision, VLM fallback, halt-on-both-fail
- Integration tests, README, CLI with benchmark mode

**Blocker**: PyPI network blocked — cannot install pyobjc/opencv for live run. Agent detects missing Quartz and exits gracefully.

## Next
- Install pyobjc-framework-Quartz + opencv when network available → live benchmark
- Phase 9: Windows support (post-MVP, deferred)
- Swap VLM stub backend for real vLLM inference when GPU model available

---

## Session 5: Liquid Glass UI Revamp

### What Changed
- **GlassCompat.swift** (NEW): Abstraction layer for Liquid Glass / material fallback
  - `supportsLiquidGlass` — runtime macOS 26+ check
  - `View.glassCard(cornerRadius:)` — `.glassEffect(.regular)` on 26+, `.background(.ultraThickMaterial)` fallback
  - `View.glassSurface(cornerRadius:)` — `.glassEffect(.clear)` on 26+, `.background(.thinMaterial)` fallback
  - `View.glassButton()` / `.glassProminentButton()` — glass button styles with fallback
  - `View.glassDivider()` — subtle divider
  - `StatusPill` — routing status indicator (green/gray pill)
  - `TransportBadge` — device transport type capsule
  - Dead `GlassToggleStyle` removed (toolbar uses Buttons, not Toggles — can't apply ToggleStyle)
- **ContentView.swift** (REWRITTEN):
  - Toolbar: custom HStack → native `.toolbar` with `ToolbarItemGroup` (left: profile+status, center: mode toggles+metronome, right: actions, far-right: start/stop)
  - Device cards: glass backing via `.glassCard(cornerRadius: 20)`, 320px min width, 20px spacing, 18px padding
  - Calibration: inline panel → `.sheet` with `CalibrationSheet` struct
  - Banners: glass-backed via `.glassSurface(cornerRadius: 14)`
  - Empty state: larger icons (64pt), Setup Wizard button
  - Removed: custom `Separator()` helper, `ToolbarSpacer` calls, `.toolbar(removing: .title)`
- **SettingsView.swift**: Replaced `.buttonStyle(.bordered)` → `.glassButton()`, `.borderedProminent` → `.glassProminentButton()`
- **App.swift**: Removed `.windowToolbarStyle(.unifiedCompact)` for glass compatibility
- **Package.swift**: Deployment target bumped macOS 13 → 14
- **Metronome restored**: Toggle + BPM stepper added back to toolbar center group (was accidentally dropped in rewrite)

### Known Issues
- CalibrationSheet uses `@ObservedObject` not `@EnvironmentObject` — works but differs from rest of app
- No visual testing possible from CLI — user must launch app to verify glass appearance
- `.toolbar(removing: .title)` removed — "AudioSync" title shows in toolbar on macOS 14+
- Setup Wizard button only in empty state now (not toolbar) — deliberate declutter decision

## TODO (Next Session)

### Priority 1: Continuous Drift Fix
**Problem:** BT speakers drift ~25ppm → 1ms per 40s → 45ms off after 30min movie. Current drift correction exists but is passive/coarse (accumulator + 40-callback cooldown, only triggers when drift > 2 samples).
**Plan:**
- Strengthen existing `_driftAccumulator` logic — reduce cooldown from 40→10 callbacks for faster response
- Add per-device **drift rate estimator**: track fill-level delta over rolling 10-second window, compute ppm drift rate
- Expose drift rate via diagnostic logging + publish `@Published var driftMs: Float` per device
- Add periodic **resync pulse**: every 60s, measure if any device has drifted >10ms, apply bulk correction
- Menu bar "Resync" button (instant re-measure + bulk correction)

### Priority 2: Auto-Calibrate on Start
**Problem:** Manual chirp calibration is finicky. Users just want to press Start and have it work.
**Plan:**
- On `start()`, automatically measure each device's pipeline latency (no mic needed)
- Method: write a single impulse to each ring buffer, timestamp when HAL render callback reads it
- Compute relative latencies → set delay offsets so fastest device waits for slowest BT
- One-click: Start → auto-measure → auto-compensate → synced
- Keep acoustic calibrator as "Advanced" option for precise room measurement

### Priority 3: Visual Sync Indicator
**Problem:** Drift is invisible until it's annoying.
**Plan:**
- Per-device sync health badge on device card: 🟢 <5ms, 🟡 5-20ms, 🔴 >20ms
- Based on ring buffer fill deviation from ideal (already tracked by drift accumulator)
- Computed in diagnostic timer, published to UI via `@Published`
- Overall sync health in toolbar (worst-device status)

### Priority 4: Quick Setup Wizard
**Problem:** First-launch experience requires too much manual work.
**Plan:**
- Welcome screen with 3 steps: ① Detect speakers ② Play test tone on each (user confirms which is which) ③ Auto-calibrate
- 30 seconds to a working setup
- Persists setup state so subsequent launches skip wizard
- Integrated with existing `SetupAssistant` (BlackHole + Multi-Output creation)

### Priority 5: Menu Bar Resync Control
**Problem:** Need quick access to resync without opening full UI.
**Plan:**
- Menu bar icon (speaker wave icon)
- Dropdown: Resync All / Current Sync Status per device / Open Full App / Quit
- Resync = instant drift correction pulse (zero the accumulators, re-measure pipeline fill)

---

## Completed (Sessions 1-4)

### Session 4: Audio Quality Overhaul
- **Per-device EQ removed entirely** — crossover crackled, produced no useful benefit. Removed LinkwitzRileyCrossover class, _crossoverLookup, _crossoverOrder, all updateEQ/resetAllEQ calls, EQ UI from device cards, EQ Reset toolbar button, room correction (was tied to EQ). DeviceSettings.bass/mid/treble removed.
- **Voice Enhance fixed** — was robotic (2x high boost + 0.5x low cut replaced signal). Now adds gentle +3dB high-shelf to original signal: `signal + highpass * 0.4`. Natural sounding.
- **Reverb wet mix reduced** — too much on big speakers. Room 0.10→0.05, JazzClub 0.18→0.08, Hall 0.25→0.12, Cathedral 0.35→0.18, Stadium 0.20→0.10.
- **Auto-sync delay fix** — maxDelayMs 1000→5000, compensation clamp 500ms→2000ms, rounding 5ms→1ms for precision, added diagnostic log for latencies >500ms.
- **Calibration timing improved** — volume settle 200ms→500ms, measurement margin 1s→2s, inter-speaker gap 500ms→1s. Better for BT codec stabilization.
- **Karaoke vocal removal improved** — added 3rd notch at 800Hz (vocal fundamental), increased notch Q 0.7→1.5 (deeper rejection), reduced loudness compensation 1.4x→1.0x (was amplifying residual vocals), LF restore cutoff 200Hz→250Hz (better separation).
- **Karaoke type-checker fix** — explicit Float type annotations on filter coefficients to prevent Swift type inference timeout.

### Session 1-3: Bugs Fixed
- B1: Atomic ring buffer positions
- B2: Silence short-circuit before rb.read()
- B3: Reverb scratch buffer (no in-place mutation)
- B4: Drift correction ordering + overflow clamp
- B5: Separate L/R reverb comb channels
- B6: Crossover pre-created off audio thread
- Cathedral icon: "church" → "cross.fill" (SF Symbol didn't exist)
- Volume loss: soft clipper threshold 0.7→0.98 (was killing -3.8dB on normal audio)
- EQ crackling: per-sample ramping (0.001 rate, ~50ms convergence)
- Voice enhance crackling: same per-sample ramp fix
- BlackHole showing in device list: filtered in DeviceDiscovery

### Session 1-3: Features Added
- Soft clipper (threshold 0.98, tanh for extreme peaks only)
- Drift correction (micro ±1 sample corrections per ring buffer)
- Dynamic BT safety frames (8192 BT / 4096 wired)
- Volume ramping (smooth transitions)
- Concert hall reverb (6 presets, reduced wet mix in session 4)
- Hardware volume override (force 100% on start, restore on stop)
- Karaoke mode (3-notch vocal removal + LF restore, improved in session 4)
- Voice Enhance (gentle +3dB high-shelf, fixed in session 4)
- Karaoke ↔ Voice Enhance mutual exclusion
- Stereo width DSP (mid/side processing, kept in backend)
- Profile persistence (reverb/masterVolume/voiceEnhance/karaoke in RoomProfile)
- Compact toolbar with icon+text labels
- Enabled devices sorted first (stable within groups)
- Update Profile + Save button (floppy disk icon)
- Removed: SpeakerRole, master volume slider, Level button, Apply Learned button, CoreAudio indicator, crossover dropdown, per-device EQ (session 4), EQ Reset button (session 4), room correction (session 4)

### Files Modified
- `MultiOutputEngine.swift` — All DSP, ring buffer, HAL units, drift, HW volume override. Session 4: removed crossover/EQ, fixed voice enhance, reduced reverb, improved karaoke, fixed auto-delay compensation, removed setCrossoverMode.
- `Models.swift` — ReverbPreset, RoomProfile, DeviceSettings. Session 4: removed roomCorrection from DeviceSettings, maxDelayMs 1000→5000.
- `AppState.swift` — Global voice enhance/karaoke, profile save/restore, async operations, hot-unplug. Session 4: simplified setVoiceEnhance (no EQ manipulation), removed resetAllEQ/applyRoomCorrection/setRoomCorrection/updateEQ calls, fixed auto-sync clamping 500→2000ms, 5ms→1ms rounding.
- `ContentView.swift` — Toolbar overhaul, device cards, calibration panel. Session 4: removed EQ section from device cards, removed EQ Reset button.
- `AcousticCalibrator.swift` — Rewritten: exponential sweep 1-8kHz, 3-chirp burst, peak detection. Session 4: increased settle/wait times for BT.
- `DeviceDiscovery.swift` — BlackHole/virtual device filtering
- `SystemAudioCapturer.swift` — CoreAudio tap + SCStream fallback

### Known Issues
- XCTest unavailable via SPM CLI (use Xcode)
- Pre-existing: `DeviceManager.swift` at root has duplicate `refreshDevices()` method
- Acoustic calibrator relies on mic being able to hear the chirp (fails if speakers too quiet or room too noisy)
- BT speakers may still drift slowly — continuous correction (TODO above) will address this
- Karaoke cannot remove hard-panned or heavily processed vocals (fundamental limitation of L-R subtraction)
- Voice enhance is subtle +3dB shelf — users expecting dramatic effect may need to adjust expectations
- SyncParty extension (YouTube‑only sync) built, Cloudflare Workers signaling server added, generic icons created, Jest tests passing.
