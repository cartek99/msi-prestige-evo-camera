#!/bin/bash
# STATUS: PARKED — PLAN M3 metering sweep (off since 2026-11-11). See README.md.
# ae-sweep.sh — record the M3 metering options with the private libcamera (relay must be idle). No sudo.
#   bash tools/ae-sweep.sh LABEL [LIBDIR]
# LIBDIR = private libcamera root (default: the staged build, else /opt/libcamera-ae).
# Records ~6 s per config through the same 1080p30 + v64x2 chain as the relay, keeps frames
# 120-149 (after AE settles) as y4m, writes a PNG of frame 135 for the contact sheet.
# Configs: stock (env unset), A/B/C windows (weight 4), A + highlight guard 2% / 5%, then the same
# window and stock again while you wave (pumping check). Speaks cues if spd-say exists.
# Output: clips ~/.cache/ipu7-cam/ae-sweep-LABEL/<config>.y4m (30 frames, ~93 MB each);
#         data/ae-sweep-LABEL/<config>.png + .log (kept in the repo).
# ONLY="stock A" limits the configs (dry runs).
set -u
LABEL=${1:?usage: ae-sweep.sh LABEL [LIBDIR]}
REPO=$(cd "$(dirname "$0")/.." && pwd)
L=${2:-$HOME/.cache/ipu7-cam/lc-build/stage/opt/libcamera-ae}
[ -d "$L/lib64" ] || L=/opt/libcamera-ae
OUT=$REPO/data/ae-sweep-$LABEL; mkdir -p "$OUT"
CLIPS=$HOME/.cache/ipu7-cam/ae-sweep-$LABEL; mkdir -p "$CLIPS"
CFG=$(mktemp -d); mkdir -p "$CFG/simple"
cp /usr/share/libcamera/ipa/simple/ov5675.yaml "$CFG/simple/ov5675.yaml"
guard_cfg() {   # guard_cfg FRACTION -> dir with the same look + highlight guard
    local d; d=$(mktemp -d); mkdir -p "$d/simple"
    sed "/^  - Agc:/a\\      highlightGuard: $1\\n      highlightLevel: 0.90" "$CFG/simple/ov5675.yaml" > "$d/simple/ov5675.yaml"
    grep -q highlightGuard "$d/simple/ov5675.yaml" || { echo "could not add guard keys (no '  - Agc:' line?)" >&2; exit 1; }
    echo "$d"
}
G2=$(guard_cfg 0.02); G5=$(guard_cfg 0.05)
say() { echo ">> $*"; spd-say -w -r -10 "$*" 2>/dev/null || true; }

# The laptop camera sees the face in the lower middle (night framing y 0.58-0.66, meeting room
# 0.50-0.72; dry run 2026-11-11), so the windows sit low; the guard watches the shirt below.
A="0.30,0.35,0.40,0.45,4"; B="0.36,0.40,0.28,0.35,4"; C="0.20,0.25,0.60,0.65,4"
run() {   # run NAME AEWIN CFGDIR
    local name=$1 win=$2 cfg=$3
    [ -n "${ONLY:-}" ] && ! [[ " $ONLY " == *" $name "* ]] && return 0
    rm -f "$CLIPS/$name.y4m"
    env LD_LIBRARY_PATH="$L/lib64" GST_PLUGIN_PATH_1_0="$L/lib64/gstreamer-1.0" \
        LIBCAMERA_IPA_MODULE_PATH="$L/lib64/libcamera/ipa" LIBCAMERA_IPA_CONFIG_PATH="$cfg" \
        GST_REGISTRY_1_0="$HOME/.cache/ipu7-cam/gst-registry-private.bin" \
        LIBCAMERA_SOFTISP_AE_WINDOW="$win" LIBCAMERA_LOG_LEVELS="*:WARN,SwStatsCpu:INFO,IPASoftExposure:INFO,IPAProxy:INFO" \
        timeout 9 gst-launch-1.0 -q libcamerasrc camera-name='\\_SB_.LNK0' \
        ! video/x-raw,width=1920,height=1080,framerate=30/1 \
        ! vapostproc denoise=64 ! vapostproc denoise=64 ! videoconvert ! video/x-raw,format=I420 \
        ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=0 \
        ! y4menc ! filesink location="$CLIPS/$name.full.y4m" \
        > "$OUT/$name.log" 2>&1
    grep -E "Centre-weighted|Highlight guard|ov5675|rror" "$OUT/$name.log" | head -3
    # keep frames 120-149 only
    ffmpeg -v error -y -i "$CLIPS/$name.full.y4m" -vf "select=between(n\,120\,149)" -fps_mode passthrough "$CLIPS/$name.y4m" \
        && ffmpeg -v error -y -i "$CLIPS/$name.y4m" -vf "select=eq(n\,15)" -fps_mode passthrough -frames:v 1 "$OUT/$name.png"
    rm -f "$CLIPS/$name.full.y4m"
    echo "   $name: $(ffprobe -v error -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$CLIPS/$name.y4m" 2>/dev/null) frames kept"
}

say "Sit still and look at the screen. Starting."
run stock "" "$CFG"
run A "$A" "$CFG"
run B "$B" "$CFG"
run C "$C" "$CFG"
run A-g2 "$A" "$G2"
run A-g5 "$A" "$G5"
say "Now wave your hand in front of your face, keep waving."
run wave-stock "" "$CFG"
run wave-A "$A" "$G2"
say "Done. Thank you."
rm -rf "$CFG" "$G2" "$G5"
ls "$OUT" "$CLIPS"
