#!/usr/bin/env python3
"""
colorchecker-fit.py — solve white-balance gains + a 3x3 CCM for the OV5675
soft-ISP from a capture of a ColorChecker Classic 24 target.

Pipeline assumptions (match capture-colortarget.sh):
  - captured with IDENTITY CCM, UNITY gains, contrast=1.0
  - soft-ISP transfer is gamma 0.5 at contrast 1.0  =>  linear = (v/255)**2
So we linearize by squaring, solve WB from the grey row, then least-squares
solve the CCM to the known reference, normalizing rows to preserve white.

Usage:
  python3 colorchecker-fit.py CAPTURE.png \
      --corners "xTL,yTL xTR,yTR xBR,yBR xBL,yBL"
Corners = pixel (or 0..1 fractional) centers of the four CORNER patches, in
order: top-left (patch 1, dark skin), top-right (patch 6, bluish green),
bottom-right (patch 24, black), bottom-left (patch 19, white).
Add --printed to loosen the fit for a printed (non-reference) chart.
"""
import argparse, sys
import numpy as np
from PIL import Image

# BabelColor average sRGB (D65, 8-bit) for ColorChecker Classic, patches 1..24
REF_SRGB = np.array([
    [115, 82, 68], [194,150,130], [ 98,122,157], [ 87,108, 67], [133,128,177], [103,189,170],
    [214,126, 44], [ 80, 91,166], [193, 90, 99], [ 94, 60,108], [157,188, 64], [224,163, 46],
    [ 56, 61,150], [ 70,148, 73], [175, 54, 60], [231,199, 31], [187, 86,149], [  8,133,161],
    [243,243,242], [200,200,200], [160,160,160], [122,122,121], [ 85, 85, 85], [ 52, 52, 52],
], dtype=float)
GREY_IDX = [18, 19, 20, 21, 22, 23]  # patches 19..24 (white..black)

def srgb_to_linear(c):
    """Inverse sRGB transfer: 8-bit sRGB reference values to linear light, for the fit target."""
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)

def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055) * 255

def parse_corner(s, w, h):
    """Parse "x,y" in pixels or in 0..1 fractions of the image (fractions are scaled to pixels)."""
    x, y = (float(v) for v in s.split(","))
    if 0 <= x <= 1 and 0 <= y <= 1:
        x, y = x * w, y * h
    return np.array([x, y])

def patch_centers(corners):
    """Bilinear grid of 24 patch centers (4 rows x 6 cols) from 4 corners."""
    TL, TR, BR, BL = corners
    pts = []
    for r in range(4):
        v = r / 3.0
        left = TL + (BL - TL) * v
        right = TR + (BR - TR) * v
        for c in range(6):
            u = c / 5.0
            pts.append(left + (right - left) * u)
    return np.array(pts)  # 24x2, order patch1..24

def sample(img, centers, frac=0.35):
    """Average a small window at each center. frac = window size vs patch pitch."""
    h, w, _ = img.shape
    # estimate patch pitch from the grid
    pitch = np.linalg.norm(centers[1] - centers[0])
    half = max(2, int(pitch * frac / 2))
    out = []
    for (x, y) in centers:
        x, y = int(round(x)), int(round(y))
        p = img[max(0, y-half):y+half, max(0, x-half):x+half].reshape(-1, 3)
        out.append(p.mean(axis=0))
    return np.array(out)

def main():
    """Solve white-balance gains and a CCM from one identity-CCM capture of the chart.

    Steps: sample the 24 patches, undo the soft-ISP gamma (square), set the gains so the grey
    row is neutral (green = 1), least-squares fit a 3x3 matrix from the balanced camera RGB to
    the linear sRGB reference, then normalise each row to sum to 1 so white stays white.
    """
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--corners", required=True,
                    help='"xTL,yTL xTR,yTR xBR,yBR xBL,yBL" (px or 0..1)')
    ap.add_argument("--printed", action="store_true")
    args = ap.parse_args()

    img = np.asarray(Image.open(args.capture).convert("RGB")).astype(float)
    h, w, _ = img.shape
    corners = np.array([parse_corner(s, w, h) for s in args.corners.split()])
    if len(corners) != 4:
        sys.exit("need exactly 4 corners")

    centers = patch_centers(corners)
    raw = sample(img, centers)                 # 24x3, 0..255 gamma-encoded
    lin = (raw / 255.0) ** 2                    # undo soft-ISP gamma 0.5

    # White balance from grey patches: make R=G=B on the neutrals
    grey = lin[GREY_IDX]
    gmean = grey.mean(axis=0)
    gains = gmean[1] / gmean                    # green=1.0 reference
    gains[1] = 1.0
    wb = lin * gains                            # 24x3

    # Least-squares CCM: wb @ A ≈ target_lin  (A = M^T)
    target = srgb_to_linear(REF_SRGB)
    A, *_ = np.linalg.lstsq(wb, target, rcond=None)
    M = A.T
    # normalize rows to sum to 1 (preserve neutral / white balance)
    M = M / M.sum(axis=1, keepdims=True)

    # Evaluate
    pred = wb @ M.T
    pred_srgb = linear_to_srgb(pred)
    err = np.sqrt(((pred_srgb - REF_SRGB) ** 2).sum(axis=1))  # rough sRGB dist
    print(f"# capture: {args.capture}  ({w}x{h})")
    print(f"# WB gains  R={gains[0]:.3f}  B={gains[2]:.3f}")
    print(f"# per-patch sRGB error: mean={err.mean():.1f} max={err.max():.1f}"
          + ("   [printed chart: treat as approximate]" if args.printed else ""))
    worst = err.argsort()[-3:][::-1]
    for i in worst:
        print(f"#   worst patch {i+1}: got {pred_srgb[i].round().astype(int)} "
              f"want {REF_SRGB[i].astype(int)}")
    print()
    print("  - Awb:")
    print(f"      gains: [ {gains[0]:.3f}, {gains[2]:.3f} ]")
    print("  - Ccm:")
    print("      ccms:")
    print("        - ct: 6500")
    r = M.flatten()
    print("          ccm: [ %6.3f, %6.3f, %6.3f," % (r[0], r[1], r[2]))
    print("                 %6.3f, %6.3f, %6.3f," % (r[3], r[4], r[5]))
    print("                 %6.3f, %6.3f, %6.3f ]" % (r[6], r[7], r[8]))

if __name__ == "__main__":
    main()
