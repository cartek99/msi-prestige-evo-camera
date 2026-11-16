#!/usr/bin/env python3
"""
ghost-metric.py IN.mkv OUT.mkv [--frames 60] [--thresh 12]

Motion ghosting of a filter chain (PLAN M1 1c): mean |OUT - IN| (luma, 8-bit) over the
pixels that are MOVING in IN (|IN_t - IN_t-1| > thresh), vs the same over static pixels.
Temporal denoisers smear moving edges, so their "moving" error rises well above their
"static" error; a spatial-only filter keeps the two close. Frames are compared at
480x270 (ghosting shows at that scale; keeps it fast). IN and OUT must be frame-aligned.
Pure Pillow + ffmpeg.
"""
import argparse, subprocess
from PIL import Image, ImageChops, ImageStat

W, H = 480, 270


def frames(path, n):
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-i", path, "-frames:v", str(n),
                          "-vf", f"scale={W}:{H}:flags=area,format=gray", "-f", "rawvideo", "-"],
                         stdout=subprocess.PIPE)
    while True:
        b = p.stdout.read(W * H)
        if len(b) < W * H:
            break
        yield Image.frombytes("L", (W, H), b)
    p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp"); ap.add_argument("out")
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--thresh", type=int, default=12)
    a = ap.parse_args()
    mov_sum = mov_n = st_sum = st_n = 0.0
    prev = None
    for fi, fo in zip(frames(a.inp, a.frames), frames(a.out, a.frames)):
        if prev is not None:
            moving = ImageChops.difference(fi, prev).point(lambda v: 255 if v > a.thresh else 0)
            static = ImageChops.invert(moving)
            err = ImageChops.difference(fo, fi)
            for mask, acc in ((moving, "m"), (static, "s")):
                cnt = ImageStat.Stat(mask).sum[0] / 255
                if cnt:
                    s = ImageStat.Stat(err, mask).sum[0]
                    if acc == "m":
                        mov_sum += s; mov_n += cnt
                    else:
                        st_sum += s; st_n += cnt
        prev = fi
    mv = mov_sum / mov_n if mov_n else float("nan")
    sv = st_sum / st_n if st_n else float("nan")
    print(f"ghost_moving {mv:.2f}  ghost_static {sv:.2f}  ratio {mv / sv if sv else float('nan'):.2f}  "
          f"moving_px {100 * mov_n / (mov_n + st_n):.1f}%")


if __name__ == "__main__":
    main()
