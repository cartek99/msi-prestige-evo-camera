# Upstream libcamera: what is already there, what we send (2026-11-16, updated 2026-11-17)

Upstream moved to **gitlab.freedesktop.org/camera/libcamera** (git.libcamera.org redirects there).
Patches still go to `libcamera-devel@lists.libcamera.org` via git send-email, with DCO `Signed-off-by`.
Checked against master `da6a6ed` (v0.8.0-23, 2026-11-12).
Fedora is still on 0.7.2; the local setup is versionlocked at 0.7.2.

## What changed upstream since 0.7.2
- `src/ipa/simple` → **`src/ipa/softisp`** (namespace `ipa::softisp`, IPA `IPASoftIsp`); tuning files install to
  `share/libcamera/ipa/softisp/`, no longer `ipa/simple/`.
- **AGC** (`softisp/algorithms/agc.cpp`) is a thin wrapper around libipa `AgcAlgorithm` (Barnabás Pőcze, v8 series, Aug 2026).
  With a `CameraSensorHelper` (OV5675 has one: `libipa/camera_sensor_helper.cpp`, "ov5675") it uses
  **`AgcMeanLuminance`**, configured by tuning:
  - `relativeLuminanceTarget`: a number or a **PWL over lux** (default 0.16)
  - `AeConstraintMode` → `Normal/Highlight/Shadows/Custom` → `lower`/`upper` → `qLo`, `qHi`, `yTarget` (yTarget may be a lux PWL)
  - `AeExposureMode` (exposure/gain stages)
  - runtime `ExposureValue` control, range ±8 (`libipa/agc.cpp`, `configure()`)
  - frame rate by default stays between 15 and 30 fps (commits e334323, ee48b02)
- **AWB** uses libipa `AwbAlgorithm` (grey or bayes): `AwbEnable` + manual `ColourGains` work; saturated pixels are
  excluded from the AWB stats (7ebae53, Oct 2026).
- **LSC** (lens shading) algorithm added for softisp (18b1542).
- **Lux:** libipa `Lux` exists (`referenceExposureTime/AnalogueGain/DigitalGain/Y/Lux`), and the AGC takes `.lux`, but
  **softisp has no Lux algorithm**, so the lux-PWL targets sit at the default 500 lux.
  Kieran Bingham posted one: patchwork 26491 "[07/13] ipa: simple: Add lux algorithm to the SoftIPA" (series 5874,
  2026-04-07). Review: Milan Zamazal + Laurent Pinchart; state **changes-requested**; last reply from Kieran 2026-05-10;
  no v2. The rest of that series (AWB to libipa) has landed in another form.

## Verdict per patch
| Ours (0.7.2) | Upstream master | Verdict |
|---|---|---|
| 0001 AGC ExposureValue + tuning `exposureValue` | ExposureValue control exists; the per-sensor bias is `relativeLuminanceTarget` | **Drop.** Express the bias as `relativeLuminanceTarget` in the tuning file |
| 0002 AWB manual `gains` + AwbEnable/ColourGains | libipa Awb has AwbEnable/ColourGains | **Drop.** (A fixed gain in tuning isn't needed: we run auto WB anyway) |
| 0003 Adjust gamma/contrast/saturation defaults from tuning | `Adjust::init` still ignores tuning | **Hold.** Policy risk (look vs calibration). Send later, alone, if at all |
| 0004/0005 (M3) AE window + highlight guard | `AeConstraintMode` upper constraint = highlight guard | **Drop 0005** (tuning does it); 0004 parked |
| 0006 EV follows light (own light metric + EV ramp) | lux-PWL `relativeLuminanceTarget`/`yTarget` exist; softisp lacks Lux | **Redo** as: softisp Lux (pick up Kieran's 26491, with his OK) + PWL in tuning |
| `ov5675.yaml` (CCM, Adjust, Agc) | no softisp OV5675 file | **New**: calibration-only file (BLC, CCM, AGC constraints, Lux reference). Looks stay local |

## Proposed series
1. `ipa: softisp: Add lux algorithm` — based on Kieran's 26491 with the review points addressed (initial value, no report
   before the first estimate, docs), feeding `.lux` to the AGC. To be coordinated with Kieran on the list (his authorship kept).
2. `ipa: softisp: data: Add OV5675 tuning file` — calibrated from the Windows driver's AIQB (2026-11-17, see below):
   bayes Awb, 6 CCMs, luminance-only Lsc, Agc `AeConstraintMode` highlight constraint. Lux-PWL target and Lux reference
   values follow once softisp has a Lux algorithm.
3. (maybe, separate) `ipa: softisp: adjust: Take defaults from the tuning file`.

Author/sign-off: `Keith Carter <oss@keithbcarter.com>` (0001/0002 carry an old address; they are dropped anyway).

## Local consequence
When Fedora moves to libcamera 0.8: the stock IPA replaces ours, the tuning path becomes `ipa/softisp/ov5675.yaml`,
and the auto-v1 keys (`exposureValueBright`, `lightDark`, …) mean nothing. The file from series item 2 is also the
file this laptop needs after 0.8, so the upstream work doubles as the versionlock exit.

## AIQB calibration (2026-11-16 late → 2026-11-17)
Replaces the phone-screen-chart CCM of the first draft. What was tried, in order:
| Date | Step | Result |
|---|---|---|
| 11-16 | MSI camera package `Camera_LNL_17232_70.26100.17232.7` (download.msi.com) | Two OV5675 modules: BCAB65 (calibrated at 2592x1944, paired with the IR camera) and S5VM17 (1928x1092) |
| 11-16 | Javier Tia's `parse_aiqb.py` (series 5948) on the Lunar Lake blob | Works unchanged: 6 colour matrices 2717-6554 K, rows sum 1 |
| 11-16 | Lens shading record 28 decoded by hand (`ia_cmc_types.h`, intel/ipu7-camera-bins ipu7x) | 10 sources, 63x47 per Bayer channel, Q11; corners need x4.1-4.9 (softisp max 3.98) |
| 11-16 | `tools/aiqb-to-softisp.py` → bayes AWB + 6 x {gains, CCM, LSC 17x17} | Evening, warm LED lamp: AWB reads ~2745 K (grey world with the old file: 3600 K, lilac walls) |
| 11-16 | Full vendor LSC, and LSC at 70% | Yellow-green cast and yellow edges |
| 11-16 | `transverseNeg` 0.05 | Cast gone: the LED sits 0.044 off the CT curve towards green, default search is 0.01 |
| 11-16 | Luminance-only LSC (green grid for all channels) | Most neutral; edges no longer yellow |
| 11-17 | Daylight A/B | AIQB files: even brightness to the corners (corner/centre 0.60 → 1.01), natural colour |
| 11-17 | Raw flat field (white paper over the lens, `cam -s role=raw`) | Needed edge colour correction (R/G +4..11%, B/G −2..6%) matches the AIQB daylight table → module is BCAB65; the evening yellow came from the tungsten tables under LED light through the warm CCMs |
| 11-17 | Choice: **t05-luma** (bayes + transverseNeg 0.05, 6 CCMs, luminance-only LSC) | `upstream/ov5675.yaml`, the file in the patch |

Known cost: the calibrated CCMs (diagonal up to 2.3, 3.4 on blue at 2717 K) and the edge gains make chroma noise more
visible in dim light; softisp has no denoiser. Possible follow-up if a reviewer asks: colour LSC from the D65 table only.

