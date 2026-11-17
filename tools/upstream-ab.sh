#!/bin/bash
# upstream-ab.sh — camera A/B of tuning files on libcamera master (private build, nothing installed),
# plus a reference frame from today's relay. Started as QA Test B; now also compares the AIQB
# variants. No sudo; the relay must be idle. Each master run points LIBCAMERA_IPA_CONFIG_PATH at a
# temp dir holding one yaml as softisp/ov5675.yaml, so the build and the system stay untouched.
#   bash tools/upstream-ab.sh LABEL            runs: today master-stock master-ov5675 master-aiqb
#                                              master-aiqb-lsc70 master-aiqb-t05 master-aiqb-t05-luma
#   (master-ov5675 = upstream/ov5675.yaml, the file in the patch; the aiqb runs are its variants)
#   ONLY="master-ov5675" bash tools/upstream-ab.sh LABEL
#   FPS30=1 ...   lock 30 fps (FrameDurationLimits, as libcamerasrc framerate=30/1 does); cam alone lets AGC drop to 15 fps
# Each run: 1920x1080, 120 frames (~4 s), frames 100-119 kept. Output data/upstream-ab-LABEL/:
#   <run>.png (frame 110), <run>.log (cam --metadata), summary.txt, side-by-side.png (2 columns
#   when more than 3 runs). summary.txt per run: mean Y, clip %, centre Y, corner/centre Y
#   (vignetting), centre R/G and B/G (white balance of the face region).
set -u
LABEL=${1:?usage: upstream-ab.sh LABEL}
REPO=$(cd "$(dirname "$0")/.." && pwd)
B=${LC_UPSTREAM:-$HOME/.cache/ipu7-cam/lc-upstream/build}
CAM=$B/src/apps/cam/cam
OUT=$REPO/data/upstream-ab-$LABEL; mkdir -p "$OUT"
WORK=$HOME/.cache/ipu7-cam/upstream-ab-$LABEL; mkdir -p "$WORK"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
[ -x "$CAM" ] || { echo "no cam at $CAM"; exit 1; }
if journalctl -u libcamera-loopback -n 30 --no-pager -o cat 2>/dev/null | grep -o 'client usage: [0-9]*' | tail -1 | grep -qv ': 0$'; then
    echo "an app is using the camera through the relay: close it first"; exit 1
fi

metrics() {   # metrics PNG -> "mean Y .. clip ..% centre RGB r/g b/g"
python3 - "$1" <<'PY'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
y = ImageStat.Stat(im.convert("L")).mean[0]
px = im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata()
clip = sum(1 for p in px if max(p) >= 250) * 100 / (w * h)
c = im.crop((w * 3 // 8, h // 4, w * 5 // 8, h * 3 // 4))      # centre (face) region
r, g, b = ImageStat.Stat(c).mean
cy = ImageStat.Stat(c.convert("L")).mean[0]
k = 10                                                        # corners: 1/10 of each side
cs = [im.crop(b).convert("L") for b in ((0, 0, w // k, h // k), (w - w // k, 0, w, h // k),
                                       (0, h - h // k, w // k, h), (w - w // k, h - h // k, w, h))]
corner = sum(ImageStat.Stat(x).mean[0] for x in cs) / 4
print(f"mean Y {y:5.1f}  clip {clip:4.1f}%  centre Y {cy:5.1f}  corner/centre {corner / cy:.2f}  centre R/G {r/g:.3f} B/G {b/g:.3f}")
PY
}

want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }
result() {   # result NAME NOTE
    local name=$1 note=$2
    { echo "== $name ($note): $(metrics "$OUT/$name.png")"
      [ -f "$OUT/$name.log" ] && {
        grep -oE 'ExposureTime = [0-9]+' "$OUT/$name.log" | tail -1
        grep -oE 'AnalogueGain = [0-9.]+' "$OUT/$name.log" | tail -1
        grep -oE 'Lux = [0-9.]+' "$OUT/$name.log" | tail -1
        grep -E 'ERROR|Tuning|tuning|yaml' "$OUT/$name.log" | grep -v 'rectangle 3' | sed 's/^\[[^]]*\] *\[[0-9]*\] *//' | sort -u | head -4
      }
    } | tee -a "$OUT/summary.txt"
}

echo "# $(date '+%F %T') $LABEL ($("$CAM" -v 2>&1 | head -1))" >> "$OUT/summary.txt"

if want today; then
    echo ">> today: one frame through the relay (0.7.2 + patches + installed look + chain)"
    ffmpeg -v error -y -f v4l2 -video_size 1920x1080 -i /dev/video0 -vf "select=eq(n\,110)" -fps_mode passthrough \
        -frames:v 1 "$OUT/today.png" && result today "relay: $(cam-look 2>/dev/null | sed 's/installed look: //'), $(cam-enhance 2>/dev/null | awk '/^chain/{print $2}')"
    sleep 12   # relay lingers 10 s after the last reader; master needs the sensor free
fi

master() {   # master NAME [TUNING_YAML]
    local name=$1 yaml=${2:-} d="$WORK/$1"
    want "$name" || return 0
    echo ">> $name"
    rm -rf "$d"; mkdir -p "$d" "$TMP/$name/softisp"
    local env=(LIBCAMERA_LOG_LEVELS='*:WARN,IPAProxy:INFO')
    if [ -n "$yaml" ]; then cp "$yaml" "$TMP/$name/softisp/ov5675.yaml"; env+=(LIBCAMERA_IPA_CONFIG_PATH="$TMP/$name"); fi
    local script=(); [ -n "${FPS30:-}" ] && script=(--script "$REPO/tools/upstream-ab-30fps.yaml")
    env "${env[@]}" timeout 60 "$CAM" -c 1 --capture=120 --metadata "${script[@]}" \
        -s width=1920,height=1080,pixelformat=ABGR8888 --file="$d/frame-#.ppm" > "$OUT/$name.log" 2>&1
    local n; n=$(ls "$d" | wc -l)
    [ "$n" -ge 111 ] || { echo "  only $n frames, see $OUT/$name.log"; tail -5 "$OUT/$name.log"; return 1; }
    ls "$d" | sort | sed -n 111p | xargs -I{} ffmpeg -v error -y -i "$d/{}" "$OUT/$name.png"
    ls "$d" | sort | sed -n '1,99p' | (cd "$d" && xargs rm -f)   # keep frames 100-120
    result "$name" "$( [ -n "$yaml" ] && basename "$yaml" || echo uncalibrated.yaml )${FPS30:+, locked 30 fps}"
}
master master-stock "$(dirname "$B")/src/ipa/softisp/data/uncalibrated.yaml"   # forced: an in-tree ov5675.yaml would win otherwise
master master-ov5675 "$REPO/upstream/ov5675.yaml"
master master-aiqb "$REPO/upstream/ov5675-aiqb.yaml"             # Windows-driver AIQB: 6 CCMs, bayes AWB, full LSC
master master-aiqb-lsc70 "$REPO/upstream/ov5675-aiqb-lsc70.yaml" # same, lens shading at 70% strength
master master-aiqb-t05 "$REPO/upstream/ov5675-aiqb-t05.yaml"     # AWB may move 0.05 towards green off the CT curve (LED lamps)
master master-aiqb-t05-luma "$REPO/upstream/ov5675-aiqb-t05-luma.yaml"  # same, LSC brightness only (no colour shading)

imgs=(); for r in today master-stock master-ov5675 master-aiqb master-aiqb-lsc70 master-aiqb-t05 master-aiqb-t05-luma; do [ -f "$OUT/$r.png" ] && imgs+=("$OUT/$r.png"); done
if [ "${#imgs[@]}" -ge 2 ]; then
    args=(); for i in "${imgs[@]}"; do args+=(-i "$i"); done
    f=""; for k in $(seq 0 $((${#imgs[@]} - 1))); do f+="[$k:v]scale=960:540,drawtext=text='$(basename "${imgs[$k]}" .png)':x=10:y=10:fontsize=28:fontcolor=yellow:box=1:boxcolor=black@0.5[v$k];"; done
    for k in $(seq 0 $((${#imgs[@]} - 1))); do f+="[v$k]"; done
    n=${#imgs[@]}
    if [ "$n" -le 3 ]; then stack="hstack=inputs=$n"
    else                    # two columns
        lay=""; for k in $(seq 0 $((n - 1))); do lay+="$((k % 2 * 960))_$((k / 2 * 540))|"; done
        stack="xstack=inputs=$n:layout=${lay%|}:fill=black"
    fi
    ffmpeg -v error -y "${args[@]}" -filter_complex "${f}${stack}" "$OUT/side-by-side.png" && echo "side by side: $OUT/side-by-side.png"
fi
echo "frames kept in $WORK (delete when done)"
