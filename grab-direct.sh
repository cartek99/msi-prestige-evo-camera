#!/bin/bash
# grab-direct.sh — grab ONE settled frame straight from libcamera (the built-in
# camera, NOT via the relay), optionally with a test tuning dir and extra
# libcamerasrc properties. Used for A/B colour diagnosis on libcamera 0.7.x.
#
#   bash grab-direct.sh OUT.png [TUNING_DIR] [extra libcamerasrc props...]
#   e.g. bash grab-direct.sh /tmp/a.png ""                      # system tuning
#        bash grab-direct.sh /tmp/b.png ~/ipu7-cam-fix/ipa-test saturation=1.4
#
# TUNING_DIR must contain simple/ov5675.yaml. Prints frame mean + face-box mean.
# Pinned to \_SB_.LNK0 (libcamera lists a plugged-in C922 first).
set -e
OUT=${1:?out.png}; CFG=${2:-}; shift 2 2>/dev/null || shift $#
TMP=$(mktemp -d /tmp/grab.XXXXXX)
ENV=()
[ -n "$CFG" ] && ENV=(LIBCAMERA_IPA_CONFIG_PATH="$CFG")
env "${ENV[@]}" timeout 20 gst-launch-1.0 -q libcamerasrc camera-name='\\_SB_.LNK0' "$@" \
    ! video/x-raw,format=RGBx,width=1280,height=720 ! videoconvert \
    ! identity eos-after=75 ! pngenc ! multifilesink location="$TMP/f-%03d.png" max-files=3 >/dev/null 2>&1 || true
# num-buffers on the sink is ignored by some versions; fall back to the last file
LAST=$(ls "$TMP"/f-*.png 2>/dev/null | sort | tail -1)
[ -n "$LAST" ] || { echo "FAIL: no frames (camera busy? fuser /dev/media0)"; rm -rf "$TMP"; exit 1; }
cp "$LAST" "$OUT"; rm -rf "$TMP"
python3 - "$OUT" <<'PY' 2>/dev/null || true
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
face = im.crop((int(w*.44), int(h*.53), int(w*.56), int(h*.78)))
f = ImageStat.Stat(face).mean; a = ImageStat.Stat(im).mean
def chroma(m): return max(m) - min(m)
print(f"{sys.argv[1]}: frame mean {sum(a)/3:.0f}  face RGB {[round(x) for x in f]} "
      f"face lum {sum(f)/3/255:.2f} face chroma {chroma(f):.0f}")
PY
