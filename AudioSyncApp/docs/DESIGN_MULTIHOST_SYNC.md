# Design Doc: Multi-Host Sync

## Concept
Sync audio playback across multiple Macs on the same LAN. Each Mac drives its own set of speakers. A master clock keeps all hosts sample-aligned to prevent drift, enabling wall-to-wall audio coverage across a large space (house, office, venue).

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  MASTER HOST                     │
│  ┌──────────┐   ┌──────────┐   ┌──────────────┐  │
│  │ System   │──►│ Capture  │──►│ Clock + NTP   │  │
│  │ Audio    │   │ (SCStream│   │ Sync Server   │  │
│  └──────────┘   └──────────┘   └──────┬───────┘  │
│                                       │          │
│  ┌──────────────────────────────────┐ │          │
│  │ Multi-Output Engine (local)      │◄┘          │
│  │ Ring Buffers → HAL → Speakers    │            │
│  └──────────────────────────────────┘            │
└────────────────────┬────────────────────────────┘
                     │ Network (LAN)
         ┌───────────┴───────────┐
         ▼                       ▼
┌─────────────────┐    ┌─────────────────┐
│   SLAVE HOST 1   │    │   SLAVE HOST 2   │
│ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │NTP Client   │ │    │ │NTP Client   │ │
│ │Clock Sync   │ │    │ │Clock Sync   │ │
│ └──────┬──────┘ │    │ └──────┬──────┘ │
│        ▼        │    │        ▼        │
│ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │Network Rx   │ │    │ │Network Rx   │ │
│ │(UDP audio)  │ │    │ │(UDP audio)  │ │
│ └──────┬──────┘ │    │ └──────┬──────┘ │
│        ▼        │    │        ▼        │
│ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │Ring Buffer  │ │    │ │Ring Buffer  │ │
│ │→ HAL → Spkrs│ │    │ │→ HAL → Spkrs│ │
│ └─────────────┘ │    │ └─────────────┘ │
└─────────────────┘    └─────────────────┘
```

## Components

### 1. Master Clock Synchronization
- Master broadcasts timing packets every 10ms via UDP multicast
- Each packet: `{ seq, masterTimestamp, samplePosition }`
- Slaves compute offset: `slaveOffset = masterTimestamp - localTime`
- Running average filter (EWMA α=0.01) for jitter rejection
- Target accuracy: ±1ms (good enough for audio, not sub-sample)

### 2. Audio Transport (Master → Slaves)
- Raw PCM audio sent via UDP multicast (or unicast for reliability)
- Format: same as current ring buffer (Float32, 48kHz, stereo, ~10ms chunks)
- Each chunk stamped with master clock timestamp
- Slaves buffer ~200ms ahead, play at scheduled time based on clock offset

### 3. Slave Playback
- Receive audio chunks → insert into slave ring buffer with master timestamp
- Slave HAL callback reads from ring buffer, adjusts read position based on:
  - Local clock vs master clock offset
  - Target play time = masterTimestamp + offset + bufferDelay
- Same drift correction logic as current BT implementation (proportional nudge)
- Per-slave delay compensation (user can add offset per slave host)

### 4. Discovery & Topology
- Bonjour `_multiaudio._tcp` for host discovery
- Master election: highest IP or user-designated
- Heartbeat: each host broadcasts status every 2s
- Auto-failover: if master dies, highest-priority slave takes over

### 5. Network Protocol
```
Packet types:
  CLOCK_SYNC     → { seq, masterTime, samplePos }         (10ms interval)
  AUDIO_CHUNK    → { seq, timestamp, payload[Float32*N] } (per callback)
  HEARTBEAT      → { hostName, role, deviceCount, health } (2s interval)
  TOPOLOGY_REQ   → "who is master?"                      (on join)
  TOPOLOGY_RESP  → { masterAddr, hostList }               (reply)
```

## Technical Challenges

### Bandwidth
- Stereo Float32 @ 48kHz = 384 KB/s per stream
- Multicast: master sends once, all slaves receive — minimal bandwidth
- Unicast fallback: N × 384 KB/s (still manageable on Gigabit)
- Option: compress with Opus → ~32 KB/s, adds ~5ms latency

### Clock Drift
- Different Macs have different clock sources and crystal oscillators
- Even NTP-synced clocks drift by ±50ppm (~5ms per minute)
- Solution: continuously re-sync via master clock packets (EWMA)
- Audio sample rate mismatch: slave resamples to match (linear interpolation sufficient at ±50ppm)

### Latency Budget
```
Master capture:     ~5ms
Network send:       ~1ms (LAN)
Slave receive:      ~1ms
Slave buffer:      200ms (safety margin for jitter)
Slave HAL:          ~5ms
────────────────────────────
Total:             ~212ms end-to-end

With aggressive buffer: ~50ms buffer → ~62ms total
```
- User can configure buffer depth (trading latency for stability)
- Auto-compensate: master measures round-trip to each slave, adjusts

### Reliability
- UDP packet loss: use forward error correction (FEC) or simple redundancy (send each chunk twice)
- Slave disconnection: detect via heartbeat timeout (5s), mute output gracefully
- Master failover: slaves hold last 10s of audio, can continue briefly while re-electing

### macOS Specifics
- Need `com.apple.developer.network.multicast` entitlement for multicast
- `NWConnection` / `NWListener` from Network framework
- Background mode: app must stay awake (keep-alive, disable App Nap)
- Firewall: prompt for local network access on first launch

## Implementation Phases

### Phase 1: Proof of Concept (1-2 days)
- Master sends clock + audio via UDP unicast to one slave
- Slave receives, buffers, plays via existing HAL pipeline
- No discovery, no failover — hardcoded IP config
- Goal: verify clock sync + audio quality

### Phase 2: Discovery + Multi-Slave (1-2 days)
- Bonjour discovery, master election
- Multicast audio, multiple slaves
- Basic topology management

### Phase 3: Production Hardening (2-3 days)
- FEC/redundancy for packet loss
- Master failover
- Configurable latency/buffer tradeoff
- UI: host topology view, per-slave health, delay offset

### Phase 4: Advanced (optional)
- Opus compression option
- Adaptive buffer (auto-shrink when stable)
- Cross-host profile sync (same settings everywhere)

## Implementation Estimate
- Total: ~2500 lines Swift, 5-7 day effort for production-ready

## Alternatives Considered

### AirPlay 2
- Apple's built-in multi-speaker sync
- Pros: no custom code, Apple handles sync
- Cons: locked to AirPlay-compatible speakers, no BT, limited to ~5 devices, no custom DSP

### NTP + RTP
- Standard protocols, well understood
- Pros: RFC-compliant, interop with existing tools
- Cons: heavier stack, overkill for LAN-only, more complexity

### Simplertp / Snapcast
- Existing open-source sync solutions
- Pros: battle-tested, community
- Cons: not Swift-native, integration complexity, different architecture
