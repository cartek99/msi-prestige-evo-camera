#!/usr/bin/env python3
"""
cam_tune_ccm.py — math + YAML generation for cam-tune.sh (pure stdlib).

Final CCM = D(bright, warmth, tint) * Sat(saturation) * blend(base, identity, strength)

  base      : 9 numbers (row-major) from live/base-ccm.txt (master or a solved CCM)
  strength  : 1.0 = base as-is, 0.0 = identity (no colour correction)
  saturation: same BT.601 YCbCr scaling libcamera's Adjust::applySaturation uses
  warmth    : +w scales the R row by (1+w) and the B row by (1-w)  (runs AFTER
              grey-world AWB, so it survives AWB — this is how we warm the image)
  tint      : +t scales the G row by (1-t) (magenta), -t = greener
  bright    : uniform gain on all rows (digital lift; >1 risks clipping highlights)

Usage:
  cam_tune_ccm.py yaml  PARAMS.env BASE.txt OUT.yaml   # write a tuning file
  cam_tune_ccm.py ccm   PARAMS.env BASE.txt            # print the 9 final values
  cam_tune_ccm.py commit PARAMS.env BASE.txt MASTER.yaml NOTE  # patch master's ccm block
"""
import re
import sys
from datetime import datetime

RGB2YCC = [[0.256788235294, 0.504129411765, 0.0979058823529],
           [-0.148223529412, -0.290992156863, 0.439215686275],
           [0.439215686275, -0.367788235294, -0.0714274509804]]
YCC2RGB = [[1.16438356164, 0, 1.59602678571],
           [1.16438356164, -0.391762290094, -0.812967647235],
           [1.16438356164, 2.01723214285, 0]]


def mm(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def read_params(path):
    p = {"SAT": 1.0, "WARM": 0.0, "TINT": 0.0, "BRIGHT": 1.0, "STRENGTH": 1.0,
         "EV": 0.0, "GAMMA": 2.2, "CONTRAST": 1.0}
    for line in open(path):
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            if k in p:
                p[k] = float(v)
    return p


def read_base(path):
    vals = [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", open(path).read())]
    if len(vals) != 9:
        sys.exit(f"{path}: need 9 numbers, got {len(vals)}")
    return [vals[0:3], vals[3:6], vals[6:9]]


def final_ccm(p, base):
    s = p["STRENGTH"]
    ident = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    m = [[s * base[i][j] + (1 - s) * ident[i][j] for j in range(3)] for i in range(3)]
    sat = [[1, 0, 0], [0, p["SAT"], 0], [0, 0, p["SAT"]]]
    m = mm(mm(mm(YCC2RGB, sat), RGB2YCC), m)
    d = [p["BRIGHT"] * (1 + p["WARM"]), p["BRIGHT"] * (1 - p["TINT"]), p["BRIGHT"] * (1 - p["WARM"])]
    return [[d[i] * m[i][j] for j in range(3)] for i in range(3)]


def ccm_block(m, indent="          "):
    rows = [", ".join(f"{v:6.3f}" for v in r) for r in m]
    pad = " " * (len(indent) + len("ccm: [ "))
    return (f"{indent}ccm: [ {rows[0]},\n{pad}{rows[1]},\n{pad}{rows[2]} ]")


def params_line(p):
    return (f"sat={p['SAT']:.2f} warm={p['WARM']:+.2f} tint={p['TINT']:+.2f} "
            f"bright={p['BRIGHT']:.2f} strength={p['STRENGTH']:.2f} "
            f"ev={p['EV']:+.2f} gamma={p['GAMMA']:.2f} contrast={p['CONTRAST']:.2f}")


def tone_blocks(p):
    # Needs the patched IPA (patches/libcamera-0.7/0001 + 0003); stock ignores these keys.
    adj = f"  - Adjust:\n      gamma: {p['GAMMA']:.2f}\n      contrast: {p['CONTRAST']:.2f}\n"
    agc = f"  - Agc:\n      exposureValue: {p['EV']:.2f}\n"
    return adj, agc


def main():
    cmd = sys.argv[1]
    p = read_params(sys.argv[2])
    m = final_ccm(p, read_base(sys.argv[3]))
    if cmd == "ccm":
        for r in m:
            print(" ".join(f"{v:7.3f}" for v in r))
    elif cmd == "yaml":
        with open(sys.argv[4], "w") as f:
            f.write("# SPDX-License-Identifier: CC0-1.0\n")
            f.write(f"# LIVE tuning written by cam-tune.sh {datetime.now():%Y-%m-%d %H:%M:%S}\n")
            f.write(f"# {params_line(p)}\n")
            f.write("%YAML 1.1\n---\nversion: 1\nalgorithms:\n  - BlackLevel:\n  - Awb:\n"
                    "  - Ccm:\n      ccms:\n        - ct: 6500\n")
            f.write(ccm_block(m) + "\n")
            adj, agc = tone_blocks(p)
            f.write(adj + agc + "...\n")
    elif cmd == "commit":
        master, note = sys.argv[4], sys.argv[5]
        txt = open(master).read()
        new, n = re.subn(r"^ *ccm: \[[^\]]*\]", ccm_block(m), txt, count=1, flags=re.M)
        if n != 1:
            sys.exit("could not find the ccm: [...] block in master")
        adj, agc = tone_blocks(p)
        # Keep "EV follows light" keys (IPA patch 0006) that the master already has: without them
        # the look silently drops to a fixed EV. With them, exposureValue is an offset on the ramp.
        blk = re.search(r"^  - Agc:\n((?:(?: {4,}.*|\s*#.*)\n)*)", txt, flags=re.M)
        if blk:
            keep = re.findall(r"^ {4,}(?:exposureValueBright|exposureValueDark|lightBright|lightDark):.*\n",
                              blk.group(1), flags=re.M)
            if keep:
                agc += "".join(keep)
                print("kept EV-follows-light keys; exposureValue is now an offset on the ramp")
        new, n1 = re.subn(r"^  - Adjust:\n(?:(?: {4,}.*|\s*#.*)\n)*", adj, new, count=1, flags=re.M)
        new, n2 = re.subn(r"^  - Agc:\n(?:(?: {4,}.*|\s*#.*)\n)*", agc, new, count=1, flags=re.M)
        if n1 != 1 or n2 != 1:
            sys.exit("could not find Adjust/Agc blocks in master")
        log = f"#   {datetime.now():%Y-%m-%d} cam-tune: {params_line(p)} — {note}\n"
        new = new.replace("%YAML 1.1", log + "%YAML 1.1", 1)
        open(master, "w").write(new)
        print(f"master updated: {params_line(p)}")


if __name__ == "__main__":
    main()
