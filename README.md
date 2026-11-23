# Enhanced built-in camera: OV5675 / Intel IPU7 on Fedora (MSI Prestige 13 AI+ Evo A2VMG)

Userspace image-quality work for the OV5675 MIPI camera behind Intel IPU7 (Lunar Lake), running on
libcamera's software ISP. The kernel side is done upstream and ships in Fedora's stock kernel (7.1.3 and later). This repo
covers what happens after the sensor binds: colour, exposure, noise, and getting the picture into every app.

**Scope:** Fedora 45, libcamera **0.7.2**. libcamera 0.8 renamed the soft-ISP IPA (`simple` → `softisp`)
and moved its AGC/AWB to libipa, so the 0.7.2 patches here do not apply to 0.8. The 0.8 route is the
tuning file in `upstream/` (posted to libcamera as https://patchwork.libcamera.org/patch/28936/) and the plan in `docs/UPSTREAM.md`.

## What is here
| Piece | Files | What it does |
|---|---|---|
| Tuning | `ov5675.yaml`, `looks/*.yaml` | CCM, gamma/contrast, exposure bias. `cam-look day\|night\|auto` switches looks |
| IPA patches (0.7.2) | `patches/libcamera-0.7/0001-0006` | AGC ExposureValue + tuning default (fixes clipped, pink highlights), manual AWB, Adjust defaults from tuning, EV follows scene light (0006). 0004/0005 are an experiment (centre-weighted AE), off by default |
| Relay | `packaging/fedora/`, `patches/libcamera-loopback/` | Fedora RPM of [libcamera-loopback](https://github.com/alanbato/libcamera-loopback) plus patches: stop before suspend, fall back to the plain camera, watchdog + retry. Serves "Built-in Camera (Enhanced)" to Chrome/Teams/Zoom and PipeWire apps |
| Denoise | `cam-enhance.sh`, `shaders/impulse3x3.frag` | GPU chain `v64x2i`: two VA-API denoise passes + a 3×3 impulse (speckle) filter |
| Health check | `check-cam-stack.sh` | Read-only check of kernel → libcamera → IPA → tuning → relay. Run after updates |
| Calibration | `CALIBRATION.md`, `capture-colortarget.sh`, `tools/colorchecker-fit.py` | CCM solve from a colour-target capture |
| Measurement | `tools/` | noise, clipping, ghosting, frame timing, soak tests |
| Upstream (libcamera master / 0.8) | `upstream/`, `tools/aiqb-to-softisp.py`, `tools/upstream-ab.sh`, `tools/flatfield-analyse.py`, `docs/UPSTREAM.md` | softisp tuning file calibrated from the Windows driver's AIQB (bayes AWB, 6 colour matrices, lens shading), the converter, the camera A/B and the raw flat-field check |

## Results (A2VMG, 1080p30)
- Night temporal noise (luma) 5.40 → 1.71 (−68%) with the two-pass VA-API denoise; night speckle 3156 → 17 px/frame with the impulse filter.
- The denoise adds about 11 ms latency and about 7.6% of one CPU core. A 30-minute Teams call on battery held 29.9–30.0 fps with 0 late frames.
- **Correction (2026-11-23):** until this date the live chain did no denoising. libcamera delivers RGBA, and the VA-API
  denoise silently does nothing on RGBA; the noise figures above come from offline tests on NV12. `cam-enhance.sh` now converts
  to NV12 on the GPU first, and the live static-area noise drops to about zero at 30 fps. The latency, CPU and call figures above
  were measured before this fix. Trade-off: some ghosting on fast motion (trails on moving edges); `sudo cam-enhance v64i`
  (one denoise pass) is milder.
- Works in Chrome, Teams, Zoom and GNOME Snapshot, survives suspend, and falls back to the plain camera if the GPU chain fails.

## Install (Fedora 45, libcamera 0.7.2)
Prerequisites: `v4l2loopback` 0.13 or later, which is in RPM Fusion (not in Fedora), plus build tools.
Clone to `~/ipu7-cam-fix` (messages assume that path):
```
sudo dnf install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install akmod-v4l2loopback rpmdevtools   # akmod builds the module for your kernel (Secure Boot: enrol the akmods key)
sudo dnf builddep libcamera
git clone https://github.com/cartek99/msi-prestige-evo-camera ~/ipu7-cam-fix
cd ~/ipu7-cam-fix
```
Then:
```
# 1. Pin libcamera first: an update replaces the patched module
sudo dnf versionlock add libcamera libcamera-ipa libcamera-gstreamer
# 2. Relay RPM
rpmdev-setuptree                        # creates ~/rpmbuild/{SOURCES,SPECS,...}
cp packaging/fedora/*.sysconfig packaging/fedora/*.conf packaging/fedora/*.patch ~/rpmbuild/SOURCES/
spectool -g -R packaging/fedora/libcamera-loopback.spec
rpmbuild -ba packaging/fedora/libcamera-loopback.spec
sudo dnf install ~/rpmbuild/RPMS/noarch/libcamera-loopback-*.noarch.rpm
sudo systemctl enable --now libcamera-loopback   # Fedora leaves new services off; without this the camera is gone after a reboot
# 3. Patched soft-ISP module, built from Fedora's source package
bash build-ipa-patch.sh
sudo bash apply-ipa-agc-patch.sh        # refuses on a different libcamera build; briefly opens the camera to verify
# 4. Commands, look, denoise
sudo bash install-cam-tools.sh          # cam-look, cam-enhance, cam-wp-rule, cam-ae
sudo cam-look auto && sudo cam-enhance v64x2i
bash check-cam-stack.sh
```
Rollback: `sudo cam-look day|night`, `sudo cam-enhance raw`. The spec header lists the steps to remove the relay.

## Current and historical scripts
Each script starts with a header comment; older ones carry a `STATUS:` line under the shebang.
| Status | Files |
|---|---|
| Current | `install-cam-tools.sh`, `cam-look.sh`, `cam-enhance.sh`, `cam-wp-rule.sh`, `check-cam-stack.sh`, `apply-ipa-agc-patch.sh`, `build-ipa-patch.sh`, `cam-tune.sh`, `record-clip.sh`, `grab-direct.sh`, `tools/` |
| Parked (built, off) | `cam-ae.sh`, `build-libcamera-private.sh`, `tools/ae-sweep.sh`, patches 0004/0005 |
| Historical (kept for reference) | `capture-frame.sh` (old v4l2-relayd relay), `capture-colortarget.sh`, `preview-colortarget.sh`, `auto-capture-chart.sh` (libcamera 0.5 tuning format; update `Lut` to `Adjust` before reuse), `diag-ov5675.sh` (kernel bring-up) |

## Security notes
- The relay (`libcamera-loopback`) runs as a **root system service** without systemd sandboxing, as upstream ships it.
  It reads only the camera and writes only the loopback device. Hardening it (dedicated user, `ProtectSystem=strict`)
  is a planned follow-up.
- `install-cam-tools.sh` installs root-owned copies of the scripts, so `sudo cam-look`/`cam-enhance` never run files you can edit.
  Prefer those over `sudo bash <repo script>`.

## Status
Personal project, tested on one laptop. Patches upstream to libcamera are in progress (see `docs/UPSTREAM.md`).
Built with AI assistance (Claude Code). The 0.7.2 setup is tested on the A2VMG. `upstream/ov5675.yaml` is tested on libcamera
master on the A2VMG (daylight and evening A/B, raw flat field; 2026-11-17); the steps and results are in `docs/UPSTREAM.md`.

## License
**Short version: MIT. Use, copy and change it freely; keep the copyright notice if you copy the scripts.**
Three groups of files follow the licence of the project they belong to:

| Files | Licence | Why |
|---|---|---|
| Everything not listed below (scripts, tools, shader, docs) | [MIT](LICENSE) | Easiest to reuse |
| Tuning files: `ov5675.yaml`, `looks/`, `upstream/` | [CC0-1.0](LICENSES/CC0-1.0.txt) (public domain) | Same as libcamera's own tuning files, so they can go upstream unchanged. No attribution needed |
| `patches/libcamera-0.7/` | [LGPL-2.1-or-later](LICENSES/LGPL-2.1-or-later.txt) | They change libcamera, which is LGPL |
| `patches/libcamera-loopback/`, `packaging/fedora/` | [AGPL-3.0-or-later](LICENSES/AGPL-3.0-or-later.txt) | They change and package libcamera-loopback, which is AGPL |

What this means in practice:
- **Running it on your own laptop:** no obligations.
- **Copying scripts or the shader into your project:** keep the MIT notice.
- **Shipping a patched libcamera or relay to others:** you follow libcamera's or libcamera-loopback's licence, as you would without these patches.

Per-file details are in `REUSE.toml` ([REUSE](https://reuse.software) format; check with `reuse lint`).
