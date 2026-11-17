#!/bin/bash
# STATUS: HISTORICAL — libcamera 0.5 era: the calibration tuning uses Lut (0.7 calls it Adjust). Update before reuse. See README.md.
# capture-colortarget.sh — grab calibration frames of a color target (e.g.
# ColorChecker 24) for the proper-CCM solve. Configures the pipeline for
# calibration: IDENTITY CCM, UNITY white-balance gains, neutral contrast, and
# sweeps exposure so we get one frame with the white patch bright-but-unclipped.
#
# Self-contained: uses the prebuilt patched IPA via env overrides, so it works
# whether or not apply-ipa-agc-patch.sh has been run. No sudo. Relay must be
# idle (close Teams/Chrome/Snapshot first; `fuser /dev/video0` to check).
#
# Output: samples/calib/target-ev<N>.png  → send these to the tuner.
set -e
REPO=$(cd "$(dirname "$0")" && pwd)
OUT="$REPO/samples/calib"; mkdir -p "$OUT"

# 1) clean module dir holding only the patched .so
MOD=$(mktemp -d /tmp/calib-mod.XXXXXX)
cp "$REPO/prebuilt/ipa_soft_simple.so" "$MOD/ipa_soft_simple.so"

# 2) calibration tuning: identity CCM, unity gains, no EV bias (swept below)
CFG=$(mktemp -d /tmp/calib-cfg.XXXXXX); mkdir -p "$CFG/simple"
cat > "$CFG/simple/ov5675.yaml" <<'YAML'
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
      gains: [ 1.0, 1.0 ]          # unity — capture the raw sensor response
  - Ccm:
      ccms:
        - ct: 6500
          ccm: [ 1.0, 0.0, 0.0,
                 0.0, 1.0, 0.0,
                 0.0, 0.0, 1.0 ]   # identity — no colour transform
  - Lut:
  - Agc:
...
YAML

echo "Capturing calibration frames (identity CCM, unity gains)."
echo "Hold the target flat, filling ~1/3-1/2 of frame, evenly lit, no glare."
for ev in 0.0 -0.5 -1.0 -1.5 -2.0; do
    rm -f /tmp/ct-*.png
    LIBCAMERA_IPA_MODULE_PATH="$MOD" LIBCAMERA_IPA_CONFIG_PATH="$CFG" \
    LIBCAMERA_IPA_FORCE_ISOLATION=1 \
    timeout 8 gst-launch-1.0 libcamerasrc exposure-value=$ev saturation=1.0 contrast=1.0 \
        ! video/x-raw,format=RGBx,width=1280,height=720 ! videoconvert \
        ! pngenc ! multifilesink location=/tmp/ct-%04d.png >/dev/null 2>&1 || true
    last=$(ls /tmp/ct-*.png 2>/dev/null | sort | tail -1)
    if [ -n "$last" ]; then
        cp "$last" "$OUT/target-ev${ev}.png"
        w=$(python3 -c "from PIL import Image;import numpy as np;im=np.asarray(Image.open('$OUT/target-ev${ev}.png').convert('RGB'));print(f'max={im.max()} clipped%={100*(im>=254).mean():.1f} mean={im.mean():.0f}')" 2>/dev/null)
        echo "  ev=$ev -> target-ev${ev}.png   $w"
    else
        echo "  ev=$ev FAILED (camera busy?)"
    fi
    rm -f /tmp/ct-*.png
done
rm -rf "$MOD" "$CFG"
echo "Done. Frames in $OUT/. Pick the one where the WHITE patch is ~230 (not 254+)."
echo "Send those to the tuner, or run: python3 tools/colorchecker-fit.py <png> --corners ..."
