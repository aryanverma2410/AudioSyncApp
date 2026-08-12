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

---

## Guardrails — Govern All Work In This Repo

These rules are mandatory for every agent, every session, every tool. They are enforced by guardrails-kit v1.0 + ponytail + superpowers + graphify.

### Guardrails-Kit (Always-On)

Before any code change, the guardrails routing table fires. Map your events:

| The moment you... | Read |
|---|---|
| Need >2 file edits or edits in >1 top-level directory | `~/.gemini/skills/guardrails-kit/references/PLAN.md` |
| Are about to create or modify a repo file for the first time | `~/.gemini/skills/guardrails-kit/references/CODE.md` |
| See a test/build failure you haven't reproduced | `~/.gemini/skills/guardrails-kit/references/DEBUG.md` |
| Are about to claim done/fixed/works | `~/.gemini/skills/guardrails-kit/references/VERIFY.md` |
| Are reading a 3rd file over 300 lines or >50 search hits | `~/.gemini/skills/guardrails-kit/references/EFFICIENCY.md` |
| Returning from compaction/resume or no docs/STATE.md | `~/.gemini/skills/guardrails-kit/references/SESSION.md` |

Iron rules (non-negotiable):
- **Read before edit**: read_file the enclosing function/class + imports before first replace. Under 250 lines, read it all.
- **Replace, don't rewrite**: modify existing files with replace, never write_file (sole exception: the rewrite procedure in CODE.md).
- **Reference sweep**: after changing any signature, symbol name, return shape, route, or enum — grep the old name repo-wide. Missed callers break silently.
- **Real signatures only**: unfamiliar API with 2+ args → paste its real signature first.
- **Verified or EDITED-UNVERIFIED**: claim done only beside fresh command output. Otherwise report `EDITED-UNVERIFIED: <file>`.
- **No hedging**: never write "should work" / "likely resolves" / "ought to now". Only: `Verified: <cmd> -> <result>` or `UNVERIFIED — to confirm, run: <cmd>`.
- **Trace evidence**: user names a bug location → that's a hypothesis. Trace to file:line before editing.
- **Minimal change**: change only lines the task requires. Log other findings as `NOTED (not done): <thing> <file:line>`.
- **Explicit null checks**: never truthiness-check values that can be 0, "" or false. Compare to nil/None explicitly.
- **Look, don't guess**: about to write "probably" / "presumably" / "I assume" about repo code → run the grep_search instead.

Hard stops:
- NEVER weaken a failing test to make it pass.
- NEVER git push unless explicitly asked.
- NEVER pkill by image name → find PID by port.
- NEVER delete files/branches/reset without pasting what's lost and getting approval.

### Ponytail (Lazy Senior Developer)

Active every response. Default: **full** intensity. The ladder:

1. **Does this need to exist?** Speculative need = skip. (YAGNI)
2. **Already in this codebase?** Reuse before re-implementing.
3. **Stdlib does it?** Use it.
4. **Native platform feature?** Native over dependency.
5. **Already-installed dependency?** Use it. Never add a new one for what a few lines can do.
6. **One line?** One line.
7. **Only then:** minimum code that works.

Rules: no unrequested abstractions, no boilerplate "for later", deletion over addition, fewest files, shortest working diff. Mark deliberate shortcuts with `# ponytail: <ceiling>, <upgrade path>`.

### Superpowers (Structured Workflows)

When the task matches, load the referenced workflow:
- **Brainstorming** → `~/.gemini/skills/superpowers/references/collaboration/brainstorming.md`
- **Writing plans** → `~/.gemini/skills/superpowers/references/collaboration/writing-plans.md`
- **Executing plans** → `~/.gemini/skills/superpowers/references/collaboration/executing-plans.md`
- **Systematic debugging** → `~/.gemini/skills/superpowers/references/debugging/systematic-debugging.md`
- **Root cause tracing** → `~/.gemini/skills/superpowers/references/debugging/root-cause-tracing.md`
- **TDD** → `~/.gemini/skills/superpowers/references/testing/test-driven-development.md`
- **When stuck** → `~/.gemini/skills/superpowers/references/problem-solving/when-stuck.md`
- **Dispatching parallel agents** → `~/.gemini/skills/superpowers/references/collaboration/dispatching-parallel-agents.md`

### Graphify (Knowledge Graph)

The project has a queryable knowledge graph built from its source code. Once built (via `/graphify /Users/root1/home/Anti`), the graph lives in `graphify-out/`.

- **Query**: `graphify query "<question>"` — BFS/DFS traversal of the codebase graph
- **Path**: `graphify path "<concept1>" "<concept2>"` — shortest path between concepts
- **Explain**: `graphify explain "<concept>"` — plain-language explanation
- **Update**: `graphify /Users/root1/home/Anti --update` — incremental rebuild on changed files

When `graphify-out/graph.json` exists, answer codebase questions from the graph before re-reading files.

---

## Sub-Project Specific Rules

### AudioSyncApp
- **Build**: `cd AudioSyncApp && swift build`
- **Test**: `cd AudioSyncApp && swift test`
- **Known bug**: BT crackling from IOProc malloc + ring buffer read-position coupling (see `docs/STATE.md`)
- **Never**: allocate on the audio thread. Pre-allocate buffers in CallbackBox.
- **Never**: derive read position from write position in ring buffers. Independent tracking.

### AirFoilRouter
- Xcode project — no SPM build from CLI. Open `.xcodeproj` in Xcode.
- Uses ScreenCaptureKit `SCStream` for system audio tap.

### BlueSync
- Two iterations (v1, v2). Template-generated. Minimal customization.

### workflow_automation
- Python + Selenium. `pip install -r requirements.txt` before running.
- Credentials in `settings.json` — never commit or log.

### Jobhunt/
- Has its own `AGENTS.md` — check it for sub-project specific rules.
- Python-heavy: pytest, requirements.txt per sub-module.

---

## OpenCode Integration

This project is configured for [OpenCode](https://opencode.ai) with:

| Feature | Details |
|---|---|
| **Agents** | `audio-engineer` (CoreAudio/AVFoundation specialist), `swiftui-builder` (surgical SwiftUI editor) |
| **Commands** | `/audiobuild`, `/audiotest`, `/deviceaudit`, `/graphquery` |
| **MCP** | Graphify server for codebase knowledge graph queries |
| **Plugins** | caveman (terse output), vibeguard (auto-guards) |
| **Graph** | Built via `/graphify /Users/root1/home/Anti`, queried via `/graphquery` |

### Quick Reference
- `/audiobuild` — Build AudioSyncApp
- `/audiotest` — Run AudioSyncApp tests
- `/deviceaudit` — Audit DeviceManager/CoreAudio patterns across all sub-projects (read-only)
- `/graphquery <question>` — Query the knowledge graph
- `/vibecheck` — Full project health audit
- `/driftcheck` — Check for AI drift in working tree
- `/commitcheck` — Pre-commit safety scan
- `/secscan` — Security vulnerability scan
- `/scaffold` — Verify project scaffolding
- `/depcheck` — Dependency health audit

---

## Default Skills for Coding

When working on code in this repo, always load these skills first:
- **caveman** — Compress output to ~65% tokens (drop filler, keep substance)
- **ponytail** — Lazy senior dev rules: minimum code that works, YAGNI
- **superpowers** — Structured workflows (TDD, debugging, planning)

These load automatically before any coding task. They are lightweight and do not change behavior for non-coding work.

## Session State

All active work is tracked in `docs/STATE.md`. If it doesn't exist, create it per guardrails-kit SESSION.md S2. Every session must:
1. Read `docs/STATE.md` at start
2. Update Goal/Now/Next as work progresses
3. Record constraints, decisions, facts, and failed attempts
4. Before claiming done, run verification per guardrails-kit VERIFY.md
