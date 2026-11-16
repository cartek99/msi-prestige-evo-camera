#!/usr/bin/env python3
"""contact-sheet.py — side-by-side 100% crops of one frame from several clips, labelled.

  contact-sheet.py OUT.png NAME=CLIP.mkv [NAME=CLIP.mkv ...]
                   [--frame 30] [--box 700,380,1300,720] [--cols 2] [--zoom 1]

Used by tools/denoise-sweep.sh (ffmpeg chains) and tools/gst-denoise-sweep.py (relay chains).
Needs ffmpeg + Pillow.
"""
import argparse, os, subprocess, tempfile
from PIL import Image, ImageDraw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("clips", nargs="+", help="NAME=PATH")
    ap.add_argument("--frame", type=int, default=30)
    ap.add_argument("--box", default="700,380,1300,720", help="x0,y0,x1,y1 in pixels")
    ap.add_argument("--cols", type=int, default=2)
    ap.add_argument("--zoom", type=int, default=1, help="nearest-neighbour upscale of each tile")
    a = ap.parse_args()
    box = tuple(int(v) for v in a.box.split(","))
    tiles = []
    with tempfile.TemporaryDirectory() as tmp:
        for spec in a.clips:
            name, path = spec.split("=", 1)
            png = os.path.join(tmp, "f.png")
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-vf",
                            f"select=eq(n\\,{a.frame})", "-frames:v", "1", png], check=True)
            t = Image.open(png).convert("RGB").crop(box)
            if a.zoom > 1:
                t = t.resize((t.width * a.zoom, t.height * a.zoom), Image.NEAREST)
            ImageDraw.Draw(t).text((8, 8), name, fill=(255, 0, 0))
            tiles.append(t)
    w, h = tiles[0].size
    cols = min(a.cols, len(tiles))
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (w * cols, h * rows))
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % cols) * w, (i // cols) * h))
    sheet.save(a.out)
    print(f"sheet: {a.out}")


if __name__ == "__main__":
    main()
