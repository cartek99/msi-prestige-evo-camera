# Color calibration (proper CCM) — acceptance-grade workflow

Goal: replace the hand-tuned CCM with one **solved** from a color target, so
colors (your pink shirt, skin, the red door) are accurate — and so `ov5675.yaml`
becomes good enough to upstream to libcamera. This is P1.2 "done properly."

## Why we need a target
The OV5675 + soft-ISP records very little chroma for some colors (your dusty-rose
shirt reads near-neutral). Eyeball-tuning the 9 CCM values + 2 white-balance gains
is 11 coupled knobs that fight each other — it oscillates. A color target with
*known* reference values lets us **least-squares solve** the CCM in one shot.

## What to get (best → budget)
1. **Calibrite / X-Rite ColorChecker Classic (24 patches)** — the standard. Best
   accuracy; what libcamera's own tuning uses. (~US$80.)
2. **ColorChecker Classic Mini / Passport** — same 24 patches, smaller/cheaper.
3. **Printed ColorChecker chart** — search "ColorChecker 24 printable", print on
   **matte** photo paper. Less accurate (printer/paper gamut) but usable; tell me
   it's printed so I can loosen the fit.
4. **DIY minimum** — a pure-white card + mid-grey card + a few known swatches.
   Gets white balance right and a rough CCM; not upstream-grade.

The solver (`tools/colorchecker-fit.py`) has the standard 24-patch reference
values baked in, so options 1–3 need no extra data from you.

## How to shoot the target (critical for a good solve)
Run `bash capture-colortarget.sh` — it configures the pipeline for calibration
(identity CCM, unity gains, neutral contrast, no highlight bias) and grabs frames.
While it runs:
- Hold the chart flat, filling **~1/3 to 1/2** of the frame, roughly centered.
- **Even, flat lighting** across the chart — your normal desk/office light. No
  glare/hotspots on the glossy patches (tilt ~10–15° to kill specular reflection).
- No shadow falling across it; no other strong colored light.
- The script takes several exposures — we keep the one where the **white patch is
  bright but NOT clipped** (~230, not 255) and the black patch is above noise.
- OPTIONAL (for a robust dual-illuminant CCM, P1.2): shoot a **second set by a
  window in daylight** (no artificial light). Two illuminants (~warm + ~daylight)
  let AWB interpolate. One set is fine to start.

Then send me the captured PNG(s) (they land in `samples/calib/`) and tell me the
4 corner patch centers, or just say "auto" and I'll locate the grid from the image.

## What I do with it
`tools/colorchecker-fit.py`:
1. Linearizes the capture (undo the fixed gamma 0.5 → square the signal).
2. Samples the 24 patches (from your 4 corners → 6×4 grid).
3. Solves white-balance gains from the 6 neutral (grey) patches.
4. Least-squares solves the 3×3 CCM mapping sensor→reference (rows normalized to
   preserve white), reports per-patch ΔE so we know the quality.
5. Emits the `gains:` + `ccm:` block to paste into `ov5675.yaml`.

Then `sudo bash apply-ipa-agc-patch.sh` installs it, and we verify against the
reference the same way we did the exposure fix.

## Interim (until you have a target)
The **white-balance fix already removes the severe cyan cast** (grey-world AWB was
the main culprit). You can install it now — it's reversible and strictly better
than the shipped cyan:
```
# already in prebuilt/; sets gains R1.25/B1.30, keeps the v9 CCM
sudo bash ~/ipu7-cam-fix/apply-ipa-agc-patch.sh
```
The proper CCM solve later just updates the `gains:`/`ccm:` values.
