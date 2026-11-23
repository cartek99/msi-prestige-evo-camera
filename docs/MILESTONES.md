# Milestones (the "PLAN Mx" tags in script headers)

| Tag | What | State |
|---|---|---|
| R | Replace v4l2-relayd with libcamera-loopback (1080p, on demand, survives suspend) | done |
| M1 | Measure noise; choose the denoise (VA-API temporal denoise, two passes at 64) | done |
| M2 | "Built-in Camera (Enhanced)" for all apps: GPU chain in the relay, fallback, watchdog, WirePlumber rule | done |
| M3 | Face/centre-weighted exposure (patches 0004/0005, private libcamera in /opt) | parked: a fixed window can't follow the face |
| M4 | Speckle filter (`shaders/impulse3x3.frag`, chain `v64x2i`) + EV follows scene light (patch 0006, look `auto-v1`) | done |
| Upstream | softisp tuning file for libcamera master, calibrated from the Windows driver's AIQB (`upstream/`, `docs/UPSTREAM.md`) | posted 2026-11-17 (patchwork 28936), awaiting review |

Measured on the A2VMG at 1080p30:
- Night temporal noise (luma) 5.40 → 1.71 with `v64x2`. Speckle 3156 → 17 px/frame with `v64x2i`. Colour within 0.3%, no ghosting.
- Correction (2026-11-23): the live chain fed RGBA to the VA-API denoise, which ignores RGBA, so live calls had the speckle
  filter but no denoise until `cam-enhance.sh` converted to NV12 first. The noise figures above are offline (NV12). Live, the
  fixed chain shows some ghosting on fast motion; `v64i` (one pass) is milder. The latency, CPU and call figures below predate the fix.
- Chain latency about 11 ms. CPU 22% of one core streaming, versus 15% plain.
- 30-minute call on battery: 29.9–30.0 fps, 0 late frames, 64 °C max, no throttling.
- M3 sweep (one daylight session): the windows had little effect, and the face position varied between sessions (y 0.22–0.72), so a fixed window misses it. `cam-ae.sh` keeps `0.30,0.35,0.40,0.45` weight 4 as its default.
