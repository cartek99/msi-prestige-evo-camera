#!/bin/bash
# ev-light-test.sh — PLAN M4b camera checks for IPA patch 0006, before installing it. No sudo;
# the relay must be idle (no app using the camera). Uses the system libcamera, and loads the IPA
# from a temp dir via LIBCAMERA_IPA_MODULE_PATH (unsigned -> isolated worker, as cam-tune does).
#   bash tools/ev-light-test.sh LABEL           compat A/B (old vs new IPA, clean-v1) + auto-v1 run
#   ONLY="auto" bash tools/ev-light-test.sh LABEL   just the auto-v1 run (evening calibration)
#   SECS=60 ONLY="auto" ...                    longer auto run (pumping check: wave, lamp on/off)
# Runs (each 9 s, frames 120-149 kept):
#   old   prebuilt/ipa_soft_simple.so.0001-0003-0.7.2-3.fc45 + looks/clean-v1.yaml
#   new   prebuilt/ipa_soft_simple.so (with 0006)           + looks/clean-v1.yaml   -> must match old
#   auto  new IPA + looks/auto-v1.yaml, IPASoftExposure:DEBUG -> "light L ... -> EV x" every 30 frames
# Output: data/ev-light-LABEL/<run>.png + .log, summary.txt (frame mean Y, clip %, exposure, light/EV).
set -u
LABEL=${1:?usage: ev-light-test.sh LABEL}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO/data/ev-light-$LABEL; mkdir -p "$OUT"
CLIPS=$HOME/.cache/ipu7-cam/ev-light-$LABEL; mkdir -p "$CLIPS"
SECS=${SECS:-9}
OLD_SO=$REPO/prebuilt/ipa_soft_simple.so.0001-0003-0.7.2-3.fc45
NEW_SO=$REPO/prebuilt/ipa_soft_simple.so
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say() { echo ">> $*"; spd-say -w -r -10 "$*" 2>/dev/null || true; }

if journalctl -u libcamera-loopback -n 30 --no-pager -o cat 2>/dev/null | grep -o 'client usage: [0-9]*' | tail -1 | grep -qv ': 0$'; then
    echo "an app is using the camera through the relay: close it first"; exit 1
fi

run() {   # run NAME SO LOOK LOGLEVELS
    local name=$1 so=$2 look=$3 lv=$4
    [ -n "${ONLY:-}" ] && ! [[ " $ONLY " == *" $name "* ]] && return 0
    mkdir -p "$TMP/$name/ipa" "$TMP/$name/cfg/simple"
    cp "$so" "$TMP/$name/ipa/ipa_soft_simple.so"
    cp "$REPO/looks/$look.yaml" "$TMP/$name/cfg/simple/ov5675.yaml"
    env LIBCAMERA_IPA_MODULE_PATH="$TMP/$name/ipa" LIBCAMERA_IPA_CONFIG_PATH="$TMP/$name/cfg" \
        LIBCAMERA_LOG_LEVELS="$lv" \
        timeout "$SECS" gst-launch-1.0 -q libcamerasrc camera-name='\\_SB_.LNK0' \
        ! video/x-raw,width=1920,height=1080,framerate=30/1 ! videoconvert ! video/x-raw,format=I420 \
        ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=0 \
        ! y4menc ! filesink location="$CLIPS/$name.full.y4m" > "$OUT/$name.log" 2>&1
    ffmpeg -v error -y -i "$CLIPS/$name.full.y4m" -vf "select=between(n\,120\,149)" -fps_mode passthrough "$CLIPS/$name.y4m" \
        && ffmpeg -v error -y -i "$CLIPS/$name.y4m" -vf "select=eq(n\,15)" -fps_mode passthrough -frames:v 1 "$OUT/$name.png"
    rm -f "$CLIPS/$name.full.y4m"
    local stats; stats=$(python3 - "$OUT/$name.png" <<'PY'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("RGB")
y = ImageStat.Stat(im.convert("L")).mean[0]
px = list(im.get_flattened_data()) if hasattr(im, "get_flattened_data") else list(im.getdata()); clip = sum(1 for p in px if max(p) >= 250) * 100 / len(px)
print(f"mean Y {y:.1f}  clip {clip:.1f}%")
PY
)
    {
        echo "== $name ($look, $(basename "$so")): $stats"
        grep -E 'Default exposure|EV follows light|IPAProxy|rror' "$OUT/$name.log" | sed 's/^\[[^]]*\] *\[[0-9]*\] *//' | head -4
        grep -o 'exp [0-9]* again [0-9.]*' "$OUT/$name.log" | tail -1
        grep -o 'light .* -> EV .*' "$OUT/$name.log" | tail -6
    } | tee -a "$OUT/summary.txt"
}

echo "# $(date '+%F %T') $LABEL" >> "$OUT/summary.txt"
say "Camera test. Sit as you would on a call."
run old "$OLD_SO" clean-v1 "*:WARN,IPASoftExposure:DEBUG,IPAProxy:INFO"
run new "$NEW_SO" clean-v1 "*:WARN,IPASoftExposure:DEBUG,IPAProxy:INFO"
run auto "$NEW_SO" auto-v1 "*:WARN,IPASoftExposure:DEBUG,IPAProxy:INFO"
say "Done."
echo "summary: $OUT/summary.txt"
