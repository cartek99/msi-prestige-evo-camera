#!/bin/bash
# STATUS: HISTORICAL — libcamera 0.5 era: the calibration tuning uses Lut (0.7 calls it Adjust). Update before reuse. See README.md.
# auto-capture-chart.sh — fully hands-off color-target capture.
#
# Opens a live preview, gives you a 20s countdown to hold the printed chart
# steady, then AUTOMATICALLY sweeps exposure and saves labeled frames, and
# closes by itself (~45s total). You never click anything — the camera view
# closing means it's done.
#
# RUN IN YOUR OWN TERMINAL:
#   bash ~/ipu7-cam-fix/auto-capture-chart.sh          # default exposure (EV -1.0)
#   bash ~/ipu7-cam-fix/auto-capture-chart.sh -1.5     # darker, if white patch clips
#   bash ~/ipu7-cam-fix/auto-capture-chart.sh -0.5     # brighter, if too dark
#
# Close any camera app (Teams/Chrome call, Zoom, Snapshot) first. This briefly
# pauses wireplumber to free the sensor (audio may blip; auto-restored on exit).
set -e
REPO=$(cd "$(dirname "$0")" && pwd)
OUT="$REPO/samples/calib"; mkdir -p "$OUT"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export CC_EV="${1:--0.3}"

# back up (never delete) any previous chart frames
if ls "$OUT"/chart-*.png >/dev/null 2>&1; then
    BK="$REPO/samples/calib-backup/chart-$(date +%s 2>/dev/null || echo prev)"
    mkdir -p "$BK"; mv "$OUT"/chart-*.png "$BK"/ 2>/dev/null || true
    echo "Backed up previous chart frames to $BK"
fi

WP_STOPPED=0; MOD=""; CFG=""
restore() {
    [ "$WP_STOPPED" = 1 ] && systemctl --user start wireplumber 2>/dev/null && echo "[wireplumber restarted — camera/audio back to normal]"
    [ -n "$MOD" ] && rm -rf "$MOD" "$CFG"
}
trap restore EXIT INT TERM

if systemctl --user is-active wireplumber >/dev/null 2>&1; then
    echo "Pausing wireplumber to free the camera (audio may blip; restored on exit)…"
    systemctl --user stop wireplumber; WP_STOPPED=1; sleep 2
fi
if fuser /dev/media1 >/dev/null 2>&1; then
    echo "⚠  Camera still busy — close any open camera app (Teams/Chrome call, Zoom,"
    echo "   Snapshot), then re-run."
    exit 1
fi

# calibration config: identity CCM, unity gains (raw sensor response for the solve)
MOD=$(mktemp -d /tmp/calib-mod.XXXXXX); cp "$REPO/prebuilt/ipa_soft_simple.so" "$MOD/"
CFG=$(mktemp -d /tmp/calib-cfg.XXXXXX); mkdir -p "$CFG/simple"
cat > "$CFG/simple/ov5675.yaml" <<'YAML'
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  - Awb:
      gains: [ 1.0, 1.0 ]
  - Ccm:
      ccms:
        - ct: 6500
          ccm: [ 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0 ]
  - Lut:
  - Agc:
...
YAML

echo "Get ready to hold the chart up to the camera. A green preview window opens now."
LIBCAMERA_IPA_MODULE_PATH="$MOD" LIBCAMERA_IPA_CONFIG_PATH="$CFG" \
LIBCAMERA_IPA_FORCE_ISOLATION=1 \
python3 "$REPO/tools/auto_capture_chart.py" "$OUT"

echo
echo "Frames saved:"; ls -1 "$OUT"/chart-*.png 2>/dev/null
echo "Tell the tuner you're done — they'll solve the CCM from these."
