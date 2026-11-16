#!/usr/bin/env python3
"""
match-reference.py — compare a laptop-camera frame with a phone photo of the same
scene and suggest cam-tune.sh settings (EV, gamma, contrast, warmth, tint,
saturation) that make the laptop look like the phone.

  match-reference.py REF.jpg FRAME.png --regions REGIONS.json --params live/params.env

REGIONS.json: {"name": {"ref": [x0,y0,x1,y1], "frame": [x0,y0,x1,y1]}, ...}
coordinates are FRACTIONS of width/height (framing differs between cameras).
Writes /tmp/match.png: [phone | laptop now | laptop simulated] with region boxes,
so a misplaced box (e.g. the subject moved) is obvious.

Model (mirrors the 0.7.2 soft-ISP shader): ... CCM -> clamp -> contrast S-curve
(linear domain, pivot 0.5, exponent tan(c*pi/4)) -> pow(1/gamma). We invert the
current frame back to linear with the current params, apply the candidate
changes, and re-encode. Pure stdlib + Pillow.
"""
import argparse, json, math
from PIL import Image, ImageDraw, ImageStat

RGB2YCC = [[0.299, 0.587, 0.114], [-0.168736, -0.331264, 0.5], [0.5, -0.418688, -0.081312]]
YCC2RGB = [[1, 0, 1.402], [1, -0.344136, -0.714136], [1, 1.772, 0]]


def mv(m, v):
    return [sum(m[i][k] * v[k] for k in range(3)) for i in range(3)]


def contrast(x, c):
    e = math.tan(min(max(c * math.pi / 4, 0), math.pi / 2 - 1e-5))
    x = min(max(x, 0.0), 1.0)
    return 0.5 * (x / 0.5) ** e if x < 0.5 else 1 - 0.5 * ((1 - x) / 0.5) ** e


def _inv(y, c):
    e = math.tan(min(max(c * math.pi / 4, 1e-5), math.pi / 2 - 1e-5))
    y = min(max(y, 0.0), 1.0)
    return 0.5 * (y / 0.5) ** (1 / e) if y < 0.5 else 1 - 0.5 * ((1 - y) / 0.5) ** (1 / e)


def to_linear(rgb8, p):
    return [_inv((v / 255) ** p["GAMMA"], p["CONTRAST"]) for v in rgb8]


def render(lin, p0, q):
    """lin = current post-CCM linear; apply deltas q relative to current p0."""
    g = 2 ** (q["EV"] - p0["EV"])
    mult = [(1 + q["WARM"]) / (1 + p0["WARM"]), (1 - q["TINT"]) / (1 - p0["TINT"]),
            (1 - q["WARM"]) / (1 - p0["WARM"])]
    x = [lin[i] * g * mult[i] for i in range(3)]
    s = q["SAT"] / p0["SAT"]
    if abs(s - 1) > 1e-6:
        y = mv(RGB2YCC, x); y[1] *= s; y[2] *= s; x = mv(YCC2RGB, y)
    return [255 * contrast(v, q["CONTRAST"]) ** (1 / q["GAMMA"]) for v in x]


def box(im, f):
    w, h = im.size
    return (int(f[0] * w), int(f[1] * h), int(f[2] * w), int(f[3] * h))


def load_params(path):
    p = {"SAT": 1.0, "WARM": 0.0, "TINT": 0.0, "BRIGHT": 1.0, "STRENGTH": 1.0,
         "EV": 0.0, "GAMMA": 2.2, "CONTRAST": 1.0}
    for line in open(path):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            if k in p:
                p[k] = float(v)
    return p


SEARCH = {"EV": (-1.0, 3.0, 0.25), "GAMMA": (1.8, 3.2, 0.1), "CONTRAST": (0.6, 1.2, 0.05),
          "WARM": (-0.15, 0.3, 0.01), "TINT": (-0.15, 0.2, 0.01), "SAT": (1.0, 1.8, 0.05)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref"); ap.add_argument("frame")
    ap.add_argument("--regions", required=True); ap.add_argument("--params", required=True)
    ap.add_argument("--fix", default="", help="comma list of params to keep fixed, e.g. EV")
    ap.add_argument("--write", default="", help="write suggested params (KEY=VAL) to this file")
    ap.add_argument("--damp", type=float, default=1.0, help="move only this fraction toward the suggestion")
    a = ap.parse_args()
    ref = Image.open(a.ref).convert("RGB"); ref.thumbnail((1200, 1200))
    fr = Image.open(a.frame).convert("RGB")
    regs = json.load(open(a.regions))
    p0 = load_params(a.params)
    pairs = []
    for n, r in regs.items():
        if n.startswith("_"):
            continue
        rv = ImageStat.Stat(ref.crop(box(ref, r["ref"]))).mean
        fv = ImageStat.Stat(fr.crop(box(fr, r["frame"]))).mean
        pairs.append((n, rv, fv, to_linear(fv, p0), r.get("weight", 1.0)))
    # highlight guard: sample pixels to estimate clipping after the change
    small = fr.resize((80, 60)); px = [to_linear(v, p0) for v in small.get_flattened_data()]
    clip0 = sum(1 for v in small.get_flattened_data() if max(v) >= 250) / len(px)

    def cost(q):
        e = sum(w * sum((x - y) ** 2 for x, y in zip(rv, render(lin, p0, q)))
                for _, rv, _, lin, w in pairs) / sum(w for *_, w in pairs) / 3
        clip = sum(1 for l in px[::3] if max(render(l, p0, q)) >= 250) / len(px[::3])
        return e + 40000 * max(0.0, clip - clip0 - 0.01)

    fixed = {k.strip().upper() for k in a.fix.split(",") if k.strip()}
    q = {k: p0[k] for k in SEARCH}
    for _ in range(4):   # coordinate descent
        for k, (lo, hi, st) in SEARCH.items():
            if k in fixed:
                continue
            n = int(round((hi - lo) / st))
            q[k] = min((lo + i * st for i in range(n + 1)), key=lambda v: cost({**q, k: v}))
    rms0 = math.sqrt(cost({k: p0[k] for k in SEARCH}))
    rms1 = math.sqrt(cost(q))

    if a.write:
        with open(a.write, "w") as f:
            for k in SEARCH:
                f.write(f"{k}={p0[k] + a.damp * (q[k] - p0[k]):.2f}\n")
            f.write(f"#RMS_NOW={rms0:.1f}\n#RMS_SUGGESTED={rms1:.1f}\n")
    print(f"{'region':9} {'phone':>16} {'laptop now':>16} {'laptop sim':>16}")
    for n, rv, fv, lin, _ in pairs:
        r = lambda v: str([round(x) for x in v])
        print(f"{n:9} {r(rv):>16} {r(fv):>16} {r(render(lin, p0, q)):>16}")
    print(f"\nRMS error (8-bit): now {rms0:.1f} -> suggested {rms1:.1f}   (clipped now {100*clip0:.1f}%)")
    print("suggested:  " + "  ".join(f"{k.lower()} {p0[k]:.2f}->{q[k]:.2f}" for k in SEARCH))
    print("apply with: " + " ; ".join(f"cam-tune.sh set {k.lower().replace('sat','sat')} {q[k]:.2f}"
                                    for k in SEARCH if abs(q[k] - p0[k]) > 1e-6 and k not in fixed))

    # visual: phone | now | simulated, with boxes
    H = 360
    def fit(im): return im.resize((int(im.width * H / im.height), H))
    sim = fr.copy(); sp = sim.load()
    for y in range(sim.height):
        for x in range(sim.width):
            sp[x, y] = tuple(int(min(255, max(0, v))) for v in render(to_linear(sp[x, y], p0), p0, q))
    tiles = [fit(ref), fit(fr), fit(sim)]
    for t, key in zip(tiles, ["ref", "frame", "frame"]):
        d = ImageDraw.Draw(t)
        for n, r in regs.items():
            if not n.startswith("_"):
                d.rectangle(box(t, r[key]), outline=(255, 0, 255), width=2)
    out = Image.new("RGB", (sum(t.width for t in tiles), H)); x = 0
    for t in tiles:
        out.paste(t, (x, 0)); x += t.width
    out.save("/tmp/match.png")
    print("visual: /tmp/match.png  [phone | laptop now | laptop simulated]")


if __name__ == "__main__":
    main()
