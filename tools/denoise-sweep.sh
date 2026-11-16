#!/bin/bash
# denoise-sweep.sh STILL.mkv WAVE.mkv REGIONS.json TAG [START] — PLAN M1 1c offline sweep.
#
# For each candidate chain: filter 60 frames of the still clip and the wave clip
# (from frame START, default 30) into samples/clips/proto-TAG-<chain>-{still,wave}.mkv,
# then report noise (cam-metrics.py), ghosting on the wave clip (ghost-metric.py),
# filter-only CPU seconds per frame and fps (decode-only run subtracted), and write a
# 100% crop contact sheet samples/clips/proto-TAG-sheet.png (row per chain, frame 30).
# Results table: samples/clips/proto-TAG-results.md
# Note: VA-API/Vulkan chains output 4:2:0, the input is 4:2:2; chroma noise drops a little from that alone.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
STILL="$1"; WAVE="$2"; REG="$3"; TAG="$4"; START="${5:-30}"; N=60
OUT="$REPO/samples/clips"; RES="$OUT/proto-$TAG-results.md"
VA="-init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va"
VK="-init_hw_device vulkan=vk -filter_hw_device vk"
vaapi() { echo "format=nv12,hwupload,$1,hwdownload,format=nv12"; }

# name | hw init | filter chain
CHAINS=(
  "none||null"
  "V16|$VA|$(vaapi denoise_vaapi=denoise=16)"
  "V32|$VA|$(vaapi denoise_vaapi=denoise=32)"
  "V64|$VA|$(vaapi denoise_vaapi=denoise=64)"
  "V32s|$VA|$(vaapi denoise_vaapi=denoise=32),$(vaapi sharpness_vaapi=sharpness=56)"   # separate pass: chained directly, the driver drops sharpness
  "V64s|$VA|$(vaapi denoise_vaapi=denoise=64),$(vaapi sharpness_vaapi=sharpness=56)"
  "A||hqdn3d=luma_spatial=2:chroma_spatial=4:luma_tmp=6:chroma_tmp=8,cas=0.4"
  "B||atadenoise=0a=0.02:0b=0.04:1a=0.02:1b=0.04:2a=0.02:2b=0.04:s=9,cas=0.4"
  "C|$VK|format=yuv420p,hwupload,nlmeans_vulkan=s=2:p=7:r=7,hwdownload,format=yuv420p,cas=0.4"
)

cpu() {   # cpu HW VF IN -> "user+sys seconds" for decoding N frames through VF to null
    local t; t=$( { /usr/bin/time -f "%U %S" ffmpeg -v error $1 -i "$3" \
        -vf "select=gte(n\\,$START),$2" -fps_mode passthrough -frames:v $N -f null - ; } 2>&1 | tail -1)
    python3 -c "a,b='$t'.split(); print(float(a)+float(b))"
}
base=$(cpu "" null "$STILL")
ffmpeg -v error -y -i "$WAVE" -vf "select=gte(n\\,$START)" -fps_mode passthrough -frames:v $N \
    -c:v ffv1 -level 3 /tmp/sweep-wave-in.mkv

{
echo "# Denoise sweep $TAG ($(date '+%F %T'))"
echo "still: \`$(basename "$STILL")\`, wave: \`$(basename "$WAVE")\`, frames $START–$((START + N - 1)). CPU = filter-only CPU seconds/frame (decode-only run subtracted)."
echo
echo "| chain | noise_t Y/C (still) | noise_s Y/C | ghost moving/static (wave) | CPU ms/frame | filter |"
echo "|---|---|---|---|---|---|"
} > "$RES"

for c in "${CHAINS[@]}"; do
    IFS='|' read -r name hw vf <<< "$c"
    for k in still wave; do
        src=$STILL; [ $k = wave ] && src=$WAVE
        ffmpeg -v error -y $hw -i "$src" -vf "select=gte(n\\,$START),$vf" -fps_mode passthrough \
            -frames:v $N -c:v ffv1 -level 3 -slices 16 "$OUT/proto-$TAG-$name-$k.mkv"
    done
    m=$(python3 "$REPO/tools/cam-metrics.py" "$OUT/proto-$TAG-$name-still.mkv" --regions "$REG" --frames 30)
    g=$(python3 "$REPO/tools/ghost-metric.py" /tmp/sweep-wave-in.mkv "$OUT/proto-$TAG-$name-wave.mkv" --frames $N)
    t=$(cpu "$hw" "$vf" "$STILL")
    ms=$(python3 -c "print(f'{max($t-$base,0)*1000/$N:.1f}')")
    v() { echo "$m" | awk -v k="$1" '$1==k{printf "%.2f",$2}'; }
    gm=$(echo "$g" | awk '{print $2}'); gs=$(echo "$g" | awk '{print $4}')
    echo "| $name | $(v noise_t_y) / $(v noise_t_c) | $(v noise_s_y) / $(v noise_s_c) | $gm / $gs | $ms | \`$vf\` |" | tee -a "$RES"
done

# contact sheet: 100% crop (face + curtain) of frame 30 from each still output, labelled
args=(); for n in "${CHAINS[@]%%|*}"; do args+=("$n=$OUT/proto-$TAG-$n-still.mkv"); done
python3 "$REPO/tools/contact-sheet.py" "$OUT/proto-$TAG-sheet.png" "${args[@]}" --frame 30 --box 700,380,1300,720
echo "results: $RES"
