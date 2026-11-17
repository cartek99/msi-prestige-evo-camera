#!/bin/bash
# guided-day-capture.sh — spoken guide (laptop speaker) for the daylight AIQB A/B and the flat-field shot.
#   bash tools/guided-day-capture.sh LABEL        e.g. day-aiqb1
# Part 1: tools/upstream-ab.sh LABEL (today, current file, AIQB t05, AIQB t05-luma), 30 fps locked, ~40 s.
# Part 2: white paper over the lens: raw Bayer (if the simple pipeline gives a raw stream) + processed frames with
#         tools/flatfield.yaml (no CCM, no LSC) → data/upstream-ab-LABEL/flatfield*. No sudo.
set -u
LABEL=${1:?usage: guided-day-capture.sh LABEL}
REPO=$(cd "$(dirname "$0")/.." && pwd)
B=${LC_UPSTREAM:-$HOME/.cache/ipu7-cam/lc-upstream/build}
CAM=$B/src/apps/cam/cam
OUT=$REPO/data/upstream-ab-$LABEL; mkdir -p "$OUT"
WORK=$HOME/.cache/ipu7-cam/upstream-ab-$LABEL; mkdir -p "$WORK"
SINK=$(pactl list short sinks | awk '/Speaker__sink/{print $2; exit}')
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

say() {   # speak on the laptop speaker (the default sink may be a muted monitor) and print
    echo "  🔊 $*"
    espeak-ng -v en-us -s 145 --stdout "$*" > "$TMP/say.wav" 2>/dev/null &&
        paplay ${SINK:+--device="$SINK"} "$TMP/say.wav" 2>/dev/null
}
countdown() { for n in 3 2 1; do say "$n"; done; }

say "Camera guide. Part one, daylight pictures. Close any app that uses the camera."
sleep 6
say "Sit where you normally sit for calls and look at the screen. Keep still for about forty seconds."
sleep 3
say "Camera on in"; countdown
ONLY="today master-ov5675 master-aiqb-t05 master-aiqb-t05-luma" FPS30=1 bash "$REPO/tools/upstream-ab.sh" "$LABEL" 2>&1 \
    | grep -v '^Exposure\|^Analogue\|IPAProxy' | tee "$OUT/guided-part1.txt"
say "Part one done. You can move."
sleep 2

say "Part two, the white paper. Take one sheet of plain white printer paper, folded in half."
sleep 4
say "Hold it flat against the camera so it covers the lens completely. Keep it flat, no wrinkles over the lens."
sleep 4
say "Lean back a little so your body doesn't shade the paper. Hold it there until I say done."
sleep 4
say "Camera on in"; countdown

mkdir -p "$TMP/ff/softisp"; cp "$REPO/tools/flatfield.yaml" "$TMP/ff/softisp/ov5675.yaml"
env=(LIBCAMERA_LOG_LEVELS='*:WARN,IPAProxy:INFO' LIBCAMERA_IPA_CONFIG_PATH="$TMP/ff")
rm -rf "$WORK/ff" "$WORK/ff-raw"; mkdir -p "$WORK/ff" "$WORK/ff-raw"
# processed + raw in one session, so the raw frames have the AGC exposure of the processed stream
env "${env[@]}" timeout 40 "$CAM" -c 1 --capture=60 --metadata --script "$REPO/tools/upstream-ab-30fps.yaml" \
    -s width=1920,height=1080,pixelformat=ABGR8888 -s role=raw \
    --file="$WORK/ff/frame-#.bin" > "$OUT/flatfield.log" 2>&1
rc=$?
if [ $rc -ne 0 ] || [ "$(ls "$WORK/ff" | wc -l)" -lt 50 ]; then
    echo "  raw + processed failed (rc $rc), processed only"; mv "$OUT/flatfield.log" "$OUT/flatfield-rawtry.log"
    rm -rf "$WORK/ff"; mkdir -p "$WORK/ff"
    env "${env[@]}" timeout 40 "$CAM" -c 1 --capture=60 --metadata --script "$REPO/tools/upstream-ab-30fps.yaml" \
        -s width=1920,height=1080,pixelformat=ABGR8888 --file="$WORK/ff/frame-#.ppm" > "$OUT/flatfield.log" 2>&1
fi
say "Done. You can take the paper away. Thank you."

echo "flat-field frames: $(ls "$WORK/ff" | wc -l) in $WORK/ff; log $OUT/flatfield.log"
grep -E 'stream[0-9]|SGRBG|ABGR|ERROR' "$OUT/flatfield.log" | sed 's/^\[[^]]*\] *\[[0-9]*\] *//' | sort -u | head -6
