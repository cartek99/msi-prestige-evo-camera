# Upstream libcamera: what is already there, what we send (2026-11-16)

Upstream moved to **gitlab.freedesktop.org/camera/libcamera** (git.libcamera.org redirects there).
Patches still go to `libcamera-devel@lists.libcamera.org` via git send-email, with DCO `Signed-off-by`.
Checked against master `da6a6ed` (v0.8.0-23, 2026-11-12), shallow clone in `~/.cache/ipu7-cam/lc-upstream`.
Fedora is still on 0.7.2; this machine is versionlocked at 0.7.2-3.

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

## Proposed series (subject to the A/B on master)
1. `ipa: softisp: Add lux algorithm` — based on Kieran's 26491 with the review points addressed (initial value, no report
   before the first estimate, docs), feeding `.lux` to the AGC. **Ask Kieran on the list first** whether he has a v2 or
   is happy for us to carry it (keep his authorship + add our Signed-off-by).
2. `ipa: softisp: data: Add OV5675 tuning file` — Ccm (state it is hand-tuned, single illuminant, unless the ColorChecker
   solve is done), Agc `AeConstraintMode` highlight constraint + lux-PWL target, Lux reference values.
3. (maybe, separate) `ipa: softisp: adjust: Take defaults from the tuning file`.

Author/sign-off: `Keith Carter <oss@keithbcarter.com>` (0001/0002 carry an old address; they are dropped anyway).

## Local consequence (premortem item 6)
When Fedora moves to libcamera 0.8: the stock IPA replaces ours, the tuning path becomes `ipa/softisp/ov5675.yaml`,
and the auto-v1 keys (`exposureValueBright`, `lightDark`, …) mean nothing. The file from series item 2 is also the
file this laptop needs after 0.8, so the upstream work doubles as the versionlock exit.
