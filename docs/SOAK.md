# M5 + Vibepollo soak checklist

Manual soak for **iPad Pro 13" M5** (Wi-Fi client) against **Vibepollo on RTX 5090** (Ethernet PC), same LAN.

## Recommended host / RF setup

- Per-client virtual display sized to the **stream** mode (16:9), not iPad native 4:3
- Force/enable **split-frame** NVENC for HEVC/AV1 on the 5090
- Stream refresh matches client request (90 or 120)
- iPad on **6 GHz or clean 5 GHz**; AP close enough for stable MCS
- Host FEC: modern defaults first; if stats show network drops with low RTT, try modestly higher FEC (never FEC=0)
- Confirm Main10/HDR bits in `/serverinfo` before HDR soak

## Stream presets to try

| Mode | Notes |
|------|--------|
| **2560x1440 @ 120**, pacing on, codec Auto | Default recommended path; expect letterboxing |
| 2560x1440 @ 90, slightly lower bitrate | If 120 shows periodic Wi-Fi stutter |
| 1920x1080 @ 120 | Alternate |
| Optional 4K @ 60 | HEVC/AV1 capable path |

Bitrate: start ~40-75 Mbps for 1440p@90/120 on Wi-Fi; slider headroom to ~150 on strong RF. ABR on Wi-Fi should open around **80% of ceiling**.

## Functional checks

- [ ] Auto codec negotiates **AV1** when host SCM includes AV1; forced HEVC still works
- [ ] Stream is **16:9 letterboxed** (not native 4:3 VDD)
- [ ] Host logs show **split-frame / multi-slice** active (`CAPABILITY_SLICES_PER_FRAME(4)`)
- [ ] Stats: watch **network drop %** and **RTT variance** (Wi-Fi health); host processing latency should stay low on 5090
- [ ] **ABR** starts below ceiling on Wi-Fi and adjusts without decoder reset when `/api/abr/capabilities` exists
- [ ] Absolute touch uses **native touch** (`LiSendTouchEvent`) when host advertises pen/touch
- [ ] Relative-mode clicks still register (30 ms synthetic press)
- [ ] Audio is not hollow / crackly with tighter queue limits
- [ ] HDR on/off; if host lacks Main10 advertisement, client shows clear SDR fallback UI
- [ ] Background / foreground resume
- [ ] Frame pacing on: **lower latency** on clean Wi-Fi (drains pending); hold-1 only briefly after underrun
- [ ] No IDR storms when ASBDL is not ready (drops instead of forcing enqueue)

## Latency pass notes (this soak)

- Late-frame drop + age gate should keep the newest frame under jitter without long backlog
- **IDRs are never skip-decoded or soft-dropped as `DR_OK`** (would falsely mark `idrFrameProcessed`); saturated ASBDL on IDR requests refresh instead
- Private LAN + Wi-Fi client uses `STREAM_CFG_LOCAL` with **packetSize 1024**
- Wi-Fi probe runs once per stream start (cached); timeout defaults to Wi-Fi-safe settings
- Single CMBlockBuffer Annex-B rewrite (in-place 4-byte / compact 3-byte); watch for decoder errors

## Renderer and state-safety scenarios (device only)

These target the risk introduced by the arrival-driven render thread and the HDR snapshot
handoff. Run each on a physical device in a Release build.

1. **Repeated stop and start.** Enter and leave the stream 20 times in a row without leaving the
   app. Watch for a hang on exit (the render thread must be joined before `stop` returns), for a
   crash inside the depacketizer (a completion landing after the queue mutex was destroyed), and
   for memory growth across iterations.
2. **Background and foreground recovery.** Send the app to the background mid-stream, wait past
   the inactivity window, and return. The stream should tear down cleanly and the next launch
   should reach video without an IDR storm.
3. **HDR toggle mid-stream.** Toggle HDR on the host while streaming, several times. Expect one
   IDR per real transition and no more; queued toggles must coalesce. Check that colors are
   correct immediately after each transition, since a torn read of the mastering primaries shows
   up as visibly wrong color rather than as an error.
4. **Renderer saturation.** Force sustained backpressure (high bitrate over congested Wi-Fi, or a
   resolution and refresh rate the device cannot keep up with). Drops are acceptable; renderer
   failures, IDR storms, and a stalled picture that never recovers are not.

## Thread Sanitizer scope

Thread Sanitizer is not wired up in CI, and the test scheme has no `enableThreadSanitizer` on its
test action, so it is a local, opt-in run.

- Coverage stops at the prebuilt uninstrumented archives in `libs/FFmpeg`, `libs/SDL2`,
  `libs/opus`, and OpenSSL.
- A whole-app run reports **pre-existing** depacketizer races on `waitingForIdrFrame`,
  `dropStatePending`, and `idrFrameProcessed`. These are upstream and are not regressions from
  the renderer or HDR work. Do not chase them here.

## Out of scope for this soak

- Off-main assemble / NAL prep
- Metal / `VTDecompressionSession` rewrite
- Disabling encryption on LAN
- FEC=0
