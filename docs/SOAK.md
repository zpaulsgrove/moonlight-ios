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

Bitrate: start ~40-75 Mbps for 1440p@90/120 on Wi-Fi; slider headroom to ~150 on strong RF.

## Functional checks

- [ ] Auto codec negotiates **AV1** when host SCM includes AV1; forced HEVC still works
- [ ] Stream is **16:9 letterboxed** (not native 4:3 VDD)
- [ ] Host logs show **split-frame / multi-slice** active (`CAPABILITY_SLICES_PER_FRAME(4)`)
- [ ] Stats: watch **network drop %** and **RTT variance** (Wi-Fi health); host processing latency should stay low on 5090
- [ ] **ABR** adjusts bitrate without decoder reset when `/api/abr/capabilities` exists
- [ ] Absolute touch uses **native touch** (`LiSendTouchEvent`) when host advertises pen/touch
- [ ] HDR on/off; if host lacks Main10 advertisement, client shows clear SDR fallback UI
- [ ] Background / foreground resume
- [ ] Frame pacing on and off

## Out of scope for this soak

- Metal / `VTDecompressionSession` rewrite
- Disabling encryption on LAN
- FEC=0
