#!/usr/bin/env python3
"""test-impulse-shader.py: behaviour tests for shaders/impulse3x3.frag, on the real GPU.

Each case is a small synthetic RGB image with a known answer. The script runs the actual shader through
GStreamer GL (the same flattening cam-enhance.sh uses), and also a pure-Python reference model of it.
It checks:
  1. the GPU result matches the reference model (within 1/255 per channel, 8-bit rounding), and
  2. the result matches the documented behaviour (docs/EXPLAIN-impulse3x3.md).
Cases marked LIMIT document known weaknesses: they pass when the weakness shows exactly as documented,
so a change in behaviour (better or worse) is noticed.

  python3 tools/test-impulse-shader.py            all cases, thresh 0.06
  THRESH=0.03 python3 tools/test-impulse-shader.py
  KEEP=1 ...                                      keep the PNGs in /tmp/impulse-test
No camera, no sudo. Needs gst-launch-1.0 with the GL plugins and Pillow. Exit code 0 = all pass.
"""
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
THRESH = float(os.environ.get("THRESH", "0.06"))
W, H = 48, 32
BG = 178                                   # 0.70 grey


def flatten_shader():
    """Same flattening as cam-enhance.sh frag(): drop // and blank lines, join into one line."""
    lines = (REPO / "shaders/impulse3x3.frag").read_text().splitlines()
    keep = [l.strip() for l in lines if l.strip() and not l.strip().startswith("//")]
    return " ".join(keep)


def run_gpu(src, dst):
    cmd = ["gst-launch-1.0", "-q", "filesrc", f"location={src}", "!", "pngdec", "!", "videoconvert", "!",
           "glupload", "!", "glcolorconvert", "!", "video/x-raw(memory:GLMemory),format=RGBA", "!",
           "glshader", f"fragment={flatten_shader()}", f"uniforms=uniforms,thresh=(float){THRESH}", "!",
           "gldownload", "!", "videoconvert", "!", "video/x-raw,format=RGB", "!", "pngenc", "!",
           "filesink", f"location={dst}"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        sys.exit(f"gst-launch failed:\n{r.stderr[-2000:]}")


def reference(img):
    """Pure-Python model: per-channel 3x3 median (edge pixels repeated), replace if BT.601 luma of
    (centre - median) exceeds THRESH."""
    px = img.load(); out = img.copy(); po = out.load()
    for y in range(H):
        for x in range(W):
            nb = [px[min(max(x + i, 0), W - 1), min(max(y + j, 0), H - 1)] for j in (-1, 0, 1) for i in (-1, 0, 1)]
            med = tuple(sorted(p[c] for p in nb)[4] for c in range(3))
            c = px[x, y]
            dev = abs(0.299 * (c[0] - med[0]) + 0.587 * (c[1] - med[1]) + 0.114 * (c[2] - med[2])) / 255
            if dev > THRESH:
                po[x, y] = med
    return out


def canvas():
    return Image.new("RGB", (W, H), (BG, BG, BG))


def put(img, pts, v):
    px = img.load()
    for x, y in pts:
        px[x, y] = v if isinstance(v, tuple) else (v, v, v)
    return img


# (name, kind, image, expected changed pixels as a set or a count, note)
#   kind PASS  = intended behaviour; LIMIT = documented weakness
def cases():
    t = round(THRESH * 255)
    c = []
    c.append(("flat image untouched", "PASS", canvas(), set(), ""))
    sp = [(10, 10), (30, 20)]
    c.append(("isolated speckles removed", "PASS", put(put(canvas(), [sp[0]], 0), [sp[1]], 255), set(sp), ""))
    edge = [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1), (20, 0), (0, 15)]
    c.append(("speckles on borders and corners removed", "PASS", put(canvas(), edge, 0), set(edge), "border = repeat edge"))
    c.append(("colour speckle (red only) removed", "PASS", put(canvas(), [(12, 12)], (255, BG, BG)), {(12, 12)}, ""))
    c.append(("blue-only speckle (+77/255) KEPT", "LIMIT", put(canvas(), [(12, 12)], (BG, BG, 255)), set(),
              "luma test: blue weighs 0.114"))
    c.append((f"speckle just above thresh ({t + 3}/255) removed", "PASS", put(canvas(), [(8, 8)], BG - t - 3), {(8, 8)}, ""))
    c.append((f"speckle just below thresh ({max(t - 3, 1)}/255) kept", "PASS", put(canvas(), [(8, 8)], BG - max(t - 3, 1)), set(), ""))
    cl = [(20, 15), (21, 15), (20, 16), (21, 16)]
    c.append(("2x2 clump removed", "PASS", put(canvas(), cl, 0), set(cl), ""))
    two = [(x, y) for y in range(H) for x in (20, 21)]
    c.append(("2-pixel line kept", "PASS", put(canvas(), two, 76), set(), ""))
    edge_img = canvas(); put(edge_img, [(x, y) for y in range(H) for x in range(24, W)], 60)
    c.append(("straight edge kept", "PASS", edge_img, set(), ""))
    soft = [(20, y) for y in range(H)]
    c.append(("1-pixel line, low contrast kept", "PASS", put(canvas(), soft, BG - max(t - 5, 1)), set(), ""))
    c.append(("1-pixel line, high contrast ERASED", "LIMIT", put(canvas(), soft, 76), set(soft), "text/eyelash risk"))
    sq = [(x, y) for y in range(8, 24) for x in range(12, 28)]
    corners = {(12, 8), (27, 8), (12, 23), (27, 23)}
    c.append(("square: 4 corner pixels rounded", "LIMIT", put(canvas(), sq, 60), corners, ""))
    c3 = [(x, y) for y in (14, 15, 16) for x in (20, 21)]
    c.append(("3x2 clump only partly removed", "LIMIT", put(canvas(), c3, 0), 4, "median outvotes up to 4"))
    return c


def main():
    tmp = Path(tempfile.mkdtemp(prefix="impulse-test-"))
    fails = 0
    print(f"impulse3x3.frag behaviour tests, thresh {THRESH} ({THRESH * 255:.1f}/255), GPU via GStreamer GL\n")
    for i, (name, kind, img, expect, note) in enumerate(cases()):
        src, dst = tmp / f"{i:02d}-in.png", tmp / f"{i:02d}-gpu.png"
        img.save(src); run_gpu(src, dst)
        gpu = Image.open(dst).convert("RGB"); ref = reference(img)
        pi, pg, pr = img.load(), gpu.load(), ref.load()
        mism = sum(1 for y in range(H) for x in range(W) if max(abs(a - b) for a, b in zip(pg[x, y], pr[x, y])) > 1)
        changed = {(x, y) for y in range(H) for x in range(W) if pg[x, y] != pi[x, y]}
        ok_behaviour = (len(changed) == expect) if isinstance(expect, int) else (changed == expect)
        ok = ok_behaviour and mism == 0
        fails += not ok
        exp_n = expect if isinstance(expect, int) else len(expect)
        print(f"{'ok  ' if ok else 'FAIL'} {kind:5} {name:45} changed {len(changed):3} (expected {exp_n:3})"
              f"  gpu-vs-model diff {mism}{'  [' + note + ']' if note else ''}")
    if os.environ.get("KEEP"):
        keep = Path("/tmp/impulse-test"); shutil.rmtree(keep, ignore_errors=True); shutil.move(str(tmp), keep)
        print(f"\nimages kept in {keep}")
    else:
        shutil.rmtree(tmp)
    print(f"\n{'ALL PASS' if not fails else f'{fails} FAILED'}")
    sys.exit(1 if fails else 0)


main()
