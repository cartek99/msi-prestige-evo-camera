#!/bin/bash
# record-clip.sh NAME [SECONDS] [SOURCE] — record a lossless test clip with voice cues (PLAN M1).
#
#   bash record-clip.sh still-day 10              # "sit still" clip from the relay (/dev/video0)
#   bash record-clip.sh wave-day 10               # NAME containing "wave" -> "now wave your hand"
#
# Output: samples/clips/NAME.mkv (FFV1, lossless, 1920x1080 YUY2 -> yuv422p) + NAME.txt (metadata).
# Records raw first (FFV1 at 1080p30 may not keep up live with max_buffers=3), keeps only
# frames after the spoken cue, then compresses to FFV1 and removes the raw file.
# No sudo. Close Chrome/Teams/Zoom first: the loopback has one reader at a time.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?usage: record-clip.sh NAME [SECONDS] [SOURCE]}"
SECS="${2:-10}"
SRC="${3:-/dev/video0}"
OUT="$REPO/samples/clips"; mkdir -p "$OUT"
RAW="$OUT/$NAME.raw.nut"; MKV="$OUT/$NAME.mkv"

say() { echo ">> $*"; spd-say -w -r -10 "$*" 2>/dev/null || espeak-ng "$*" 2>/dev/null || true; }
beep() { canberra-gtk-play -i "$1" 2>/dev/null || true; }

if [[ "$NAME" == *wave* ]]; then
    PREP="Get ready. Face the camera. When I say now, wave your hand slowly in front of you."
    GO="Now wave your hand."
else
    PREP="Get ready. Sit still and look at the camera."
    GO="Recording. Stay still."
fi

say "$PREP"
for n in 3 2 1; do echo "   $n…"; beep audio-volume-change; sleep 1; done

# The loopback gives one idle black frame, then real frames once the relay has started the
# camera (~2 s, varies). Count frames from the raw file size, cue once real frames flow, and
# keep the SECS*30 frames that arrive after the cue has been spoken.
FB=$((1920 * 1080 * 2))
ffmpeg -hide_banner -loglevel error -y -f v4l2 -input_format yuyv422 -video_size 1920x1080 \
    -framerate 30 -i "$SRC" -frames:v $(( (SECS + 30) * 30 )) -c:v rawvideo "$RAW" &
FF=$!
nframes() { echo $(( $(stat -c %s "$RAW" 2>/dev/null || echo 0) / FB )); }
t0=$SECONDS
until [ "$(nframes)" -ge 30 ]; do                # 1 s of real frames: AE/AWB settled
    kill -0 $FF 2>/dev/null || { echo "ffmpeg stopped early"; exit 1; }
    [ $((SECONDS - t0)) -gt 20 ] && { kill $FF; echo "no frames after 20 s — is the relay up?"; exit 1; }
    sleep 0.1
done
beep camera-shutter; say "$GO"
FIRST=$(nframes)
until [ "$(nframes)" -ge $((FIRST + SECS * 30 + 2)) ]; do sleep 0.1; done
kill -INT $FF; wait $FF || true
beep complete; say "Done. You can move."

ffmpeg -hide_banner -loglevel error -y -i "$RAW" -vf "select=gte(n\\,$FIRST)" -fps_mode passthrough \
    -frames:v $((SECS * 30)) -c:v ffv1 -level 3 -g 1 -slices 16 -slicecrc 1 "$MKV"
rm -f "$RAW"

FRAMES=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$MKV")
{
    echo "clip: $NAME.mkv  recorded $(date '+%F %T')  source $SRC  ${SECS}s from frame $FIRST (after the spoken cue)"
    echo "frames: $FRAMES (expect $((SECS * 30)))"
    echo "look: $(bash "$REPO/cam-look.sh" | sed 's/^installed look: //')"
    echo "relay source: $(grep -E '^LOOPBACK_SOURCE' /etc/sysconfig/libcamera-loopback 2>/dev/null || echo '?')"
} | tee "$OUT/$NAME.txt"
ls -la "$MKV"
