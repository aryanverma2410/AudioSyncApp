# Design Doc: Guest Queue Mode

## Concept
Let friends on the same WiFi submit songs to a shared queue that plays through the host's multi-speaker setup. Guests don't need the app — they use a simple web page served by AudioSync.

## Architecture

### Host Side (AudioSyncApp)
```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Web Server │◄───►│  Queue Mgr   │◄───►│  Audio Player   │
│  (port 8080)│     │  (SQLite/JSON)│     │  (AVPlayer)     │
└──────┬──────┘    └──────────────┘     └─────────────────┘
       │                                         │
       ▼                                         ▼
┌─────────────┐                          ┌─────────────────┐
│  Bonjour    │                          │  Multi-Output   │
│  Discovery  │                          │  Engine (HAL)   │
└─────────────┘                          └─────────────────┘
```

### Guest Side (Browser)
```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Discover   │────►│  Web UI      │────►│  Submit Song   │
│  (Bonjour)  │     │  (Safari)    │     │  (URL/upload)  │
└─────────────┘     └──────────────┘     └─────────────────┘
```

## Components

### 1. Embedded HTTP Server
- Lightweight Swift HTTP server using `GCDWebServer` or raw `NWListener`
- Serves: static web UI (HTML/CSS/JS), POST `/api/queue/add`, GET `/api/queue`, DELETE `/api/queue/:id`
- Runs on port 8080 (configurable)
- Bonjour broadcast: `_audioqueue._tcp` service type

### 2. Queue Manager
- Maintains ordered list of track submissions
- Each entry: `{ id, title, submitter, url/file, duration, status }`
- States: `pending → downloading → ready → playing → done`
- Persistent across restarts (JSON file in App Support)
- Vote system: guests can upvote (priority) or veto (skip)

### 3. Audio Playback
- AVPlayer instance separate from the system capture pipeline
- Routes through the existing MultiOutputEngine (as a virtual device or via injectAudioBuffer)
- Supports: Apple Music URLs, local file uploads, YouTube URLs (via yt-dlp on host)
- Gapless playback between tracks

### 4. Web UI (Guest)
- Single HTML page, no framework needed (~200 lines)
- Shows: current track, queue, add URL field, vote buttons
- WebSocket or SSE for live updates
- Mobile-responsive
- QR code displayed on host app for easy joining

### 5. Host Controls (App UI)
- Queue view in main window (toggle tab)
- Approve/deny incoming submissions (optional moderation)
- Skip, reorder, clear queue
- Show connected guests count
- Volume control for queue vs system audio (dual-source)

## Technical Challenges

### Audio Source Integration
The current engine captures **system audio** via ScreenCaptureKit. Guest queue needs a **secondary source** (AVPlayer). Two approaches:

**Option A: Dual Pipeline (Recommended)**
- Mix AVPlayer output into the system capture stream
- Use `AVAudioMix` or tap AVPlayer's audio buffer
- Both sources feed into `distributeAudioDirect` 
- Need a mixing stage before ring buffers

**Option B: Aggregate Device**
- Create a virtual aggregate that includes AVPlayer output
- System capture picks it up naturally
- Simpler but less control over mixing/volumes

### Security
- PIN-protect the queue (4-digit code shown on host)
- Rate-limit submissions per guest
- Sanitize file uploads (audio only, size limit)
- Local network only (no internet exposure)

### Network Discovery
- Bonjour `_audioqueue._tcp` broadcast
- Host advertises service with name "AudioSync @ John's House"
- Guest browser auto-discovers via `NetServiceBrowser`
- Fallback: manual IP entry shown on host screen

## Implementation Estimate
- HTTP server + queue mgr: ~800 lines Swift
- Web UI: ~300 lines HTML/CSS/JS
- Host UI integration: ~200 lines SwiftUI
- Audio mixing: ~200 lines (AVPlayer tap → ring buffer)
- Total: ~1500 lines, 3-4 day effort

## Future Extensions
- Spotify/Apple Music integration for track resolution
- Collaborative playlist export
- "Round-robin" mode (each guest gets a turn)
- Themed rooms (guest queue acts as radio station)
