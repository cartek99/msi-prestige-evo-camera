#!/bin/bash
# preview-colortarget.sh — LIVE preview while capturing calibration frames of a
# color target (ColorChecker). Opens a video window so you can align the card,
# and auto-saves a frame every second in the background (keeps the last 20).
# Uses the calibration pipeline (identity CCM, unity gains) so the preview shows
# exactly what the solver will see.
#
# RUN IT IN YOUR OWN TERMINAL (it opens a window and runs until you close it):
#   bash ~/ipu7-cam-fix/preview-colortarget.sh          # default exposure
#   bash ~/ipu7-cam-fix/preview-colortarget.sh -1.0     # darker, if white patch clips
#
# First CLOSE any camera app (Teams/Chrome call, Snapshot, Zoom). This script
# also briefly stops PipeWire's wireplumber, which otherwise holds the IPU7
# sensor open and blocks direct capture — it is auto-restarted on exit (your
# audio may blip for a few seconds during calibration; camera/audio return
# to normal after).
# When the card looks well-aligned and evenly lit, hold it steady ~2s, then
# close the window (or Ctrl-C). Frames are in samples/calib/.
set -e
REPO=$(cd "$(dirname "$0")" && pwd)
EV="${1:--0.75}"
# waylandsink renders reliably here; autovideosink picks a GL sink that fails
# silently on this Lunar Lake/xe GPU (no window). Override with SINK=ximagesink
# if the window still doesn't appear.
SINK="${SINK:-waylandsink}"
OUT="$REPO/samples/calib"; mkdir -p "$OUT"
# Preserve any previous frames instead of deleting: move them into a backup dir.
if ls "$OUT"/live-*.png >/dev/null 2>&1; then
    BK="$REPO/samples/calib-backup/prev-$(ls -t "$OUT"/live-*.png | head -1 | xargs stat -c %Y)"
    mkdir -p "$BK"; mv "$OUT"/live-*.png "$BK"/ 2>/dev/null
    echo "Backed up previous frames to $BK"
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# wireplumber (PipeWire session manager) persistently holds the IPU7 sensor, so
# direct libcamera capture can't acquire it. Stop it for the duration and ALWAYS
# restart on exit (normal close, Ctrl-C, or error).
WP_STOPPED=0; MOD=""; CFG=""
restore() { [ "$WP_STOPPED" = 1 ] && systemctl --user start wireplumber 2>/dev/null && echo "[wireplumber restarted]"; [ -n "$MOD" ] && rm -rf "$MOD" "$CFG"; }
trap restore EXIT INT TERM
if systemctl --user is-active wireplumber >/dev/null 2>&1; then
    echo "Pausing wireplumber to free the camera (audio may blip; restored on exit)…"
    systemctl --user stop wireplumber; WP_STOPPED=1; sleep 2
fi
if fuser /dev/media1 >/dev/null 2>&1; then
    echo "⚠  Camera still busy — close any open camera app (Teams/Chrome call, Snapshot,"
    echo "   Zoom) and re-run."
    exit 1
fi

# calibration config: identity CCM, unity gains (see capture-colortarget.sh)
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

echo "Opening live preview (exposure-value=$EV). Align the color card in the window."
echo "Frames auto-save to $OUT/live-###.png (last 20 kept). Close the window when done."

# tee: one branch to the screen, one throttled branch (1 fps) to a ring of PNGs
LIBCAMERA_IPA_MODULE_PATH="$MOD" LIBCAMERA_IPA_CONFIG_PATH="$CFG" \
LIBCAMERA_IPA_FORCE_ISOLATION=1 \
gst-launch-1.0 -e libcamerasrc exposure-value="$EV" saturation=1.0 contrast=1.0 \
    ! video/x-raw,format=RGBx,width=1280,height=720 ! tee name=t \
    t. ! queue leaky=downstream max-size-buffers=3 ! videoconvert ! $SINK sync=false \
    t. ! queue leaky=downstream max-size-buffers=3 ! videorate ! video/x-raw,framerate=1/1 \
       ! videoconvert ! video/x-raw,format=RGB ! pngenc ! multifilesink location="$OUT/live-%03d.png" max-files=20

echo
echo "Preview closed. Saved frames:"
ls -1 "$OUT"/live-*.png 2>/dev/null | tail -5
echo "Pick the best-aligned one (or tell the tuner to) → run tools/colorchecker-fit.py on it."
