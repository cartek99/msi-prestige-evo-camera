#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Measure the lens shading of the OV5675 from raw flat-field frames and compare it with the AIQB.

Usage: flatfield-analyse.py AIQB RAW.bin [RAW.bin ...]     (needs numpy: ~/.cache/ipu7-cam/venv)

Input: raw frames from `cam -s role=raw` on libcamera master (tools/guided-day-capture.sh), taken
with a sheet of white paper flat over the lens, so every pixel sees the same light and any
variation across the frame is the lens and sensor (shading).

Method:
  1. Average the frames (less noise), subtract the black level, split the Bayer mosaic (GRBG)
     into its four channels.
  2. Take block means at the 63x47 grid points of the AIQB tables (edge to edge), so the
     measurement and the vendor tables line up point for point.
  3. Normalise each channel on its centre. G (mean of Gr and Gb) is the brightness fall-off;
     R/G and B/G relative to the centre are the colour shading.
  4. The gain needed to flatten the image is the inverse of the fall-off. Print it next to the
     AIQB tables for daylight (D65) and tungsten (A) at a few points: centre, edges, corners.
The measured fall-off is only as even as the light on the paper; the colour ratios are more
robust, since uneven light of one colour cancels out in R/G and B/G.
Writes flatfield-grid.npz (G, R, B normalised grids) next to the first frame.
"""
import importlib.util
import os
import sys

import numpy as np

W, H = 2592, 1944          # full sensor mode, SGRBG10 stored in 16-bit little endian
BLACK_LEVEL = 64           # 0x40 at 10 bits (kernel driver; AIQB record 31 agrees)
CLIP = 1023 - BLACK_LEVEL  # a centre level near this means the flat field was overexposed
GW, GH = 63, 47            # AIQB lens-shading grid size
CJ, CI = GH // 2, GW // 2  # grid centre (row 23, column 31)
HALF = 12                  # block half-size in channel pixels (25x25 block per grid point)
SRC_D65, SRC_A = 6, 1      # cmc_light_source values: daylight D65, tungsten A


def load_aiqb_reader():
    """Import records() and read_lsc() from aiqb-to-softisp.py (one parser for both tools)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'aiqb-to-softisp.py')
    spec = importlib.util.spec_from_file_location('aiqb_to_softisp', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def block_grid(a, gw=GW, gh=GH):
    """Mean of a (2*HALF+1)^2 block of channel a at each of the gw x gh grid points (edge to edge)."""
    h, w = a.shape
    out = np.zeros((gh, gw))
    for j in range(gh):
        for i in range(gw):
            cx, cy = i * (w - 1) / (gw - 1), j * (h - 1) / (gh - 1)
            x0, x1 = int(max(0, cx - HALF)), int(min(w, cx + HALF + 1))
            y0, y1 = int(max(0, cy - HALF)), int(min(h, cy + HALF + 1))
            out[j, i] = a[y0:y1, x0:x1].mean()
    return out


def table_at(grids, ch, j, i):
    """AIQB gain at grid point (j, i), normalised on the centre: G gain, then R and B relative to G."""
    def norm(c):
        return grids[c][j, i] / grids[c][CJ, CI]
    g = (norm(ch['Gr']) + norm(ch['Gb'])) / 2
    return g, norm(ch['R']) / g, norm(ch['B']) / g


def main():
    aiqb, raws = sys.argv[1], sys.argv[2:]

    # 1. average, black level, Bayer split (GRBG: row 0 = Gr R, row 1 = B Gb)
    img = np.mean([np.fromfile(f, '<u2', W * H).reshape(H, W).astype(np.float64) for f in raws], axis=0)
    print(f'frames {len(raws)}, raw max {img.max():.0f}, mean {img.mean():.1f}')
    img = np.clip(img - BLACK_LEVEL, 0, None)
    chans = {'Gr': img[0::2, 0::2], 'R': img[0::2, 1::2], 'B': img[1::2, 0::2], 'Gb': img[1::2, 1::2]}

    # 2.-3. block means on the AIQB grid, normalised on the centre
    meas = {k: block_grid(v) for k, v in chans.items()}
    cen = {k: v[CJ, CI] for k, v in meas.items()}
    print('centre levels', {k: round(v, 1) for k, v in cen.items()}, f'(clipped if near {CLIP})')
    G = (meas['Gr'] / cen['Gr'] + meas['Gb'] / cen['Gb']) / 2
    Rn, Bn = meas['R'] / cen['R'], meas['B'] / cen['B']

    # vendor tables (record 28), channel order from the blob's own grid indices
    mod = load_aiqb_reader()
    data = open(aiqb, 'rb').read()
    lsc, cell, w, h = mod.read_lsc(data, *mod.records(data)[mod.LSC_ID])
    assert (w, h) == (GW, GH), (w, h)
    tabs = {src: [np.array(g, float).reshape(h, w) for g in grids] for src, grids in lsc.items()}
    ch = dict(Gr=cell[(0, 0)], R=cell[(0, 1)], B=cell[(1, 0)], Gb=cell[(1, 1)])

    # 4. measured shading, the gain it needs, and the vendor gains at the same points
    pts = {'centre': (CJ, CI), 'left': (CJ, 0), 'right': (CJ, GW - 1), 'top': (0, CI), 'bottom': (GH - 1, CI),
           'TL': (0, 0), 'TR': (0, GW - 1), 'BL': (GH - 1, 0), 'BR': (GH - 1, GW - 1),
           'mid-left': (CJ, 15), 'mid-top': (11, CI)}
    print('\nmeasured: G falloff (1 = centre), and colour shading R/G, B/G relative to centre')
    print('   point     G     R/G    B/G   | needed gain G  | AIQB D65 gain G  R/G   B/G | AIQB A gain G  R/G   B/G')
    for k, (j, i) in pts.items():
        g6, r6, b6 = table_at(tabs[SRC_D65], ch, j, i)
        ga, ra, ba = table_at(tabs[SRC_A], ch, j, i)
        # needed gain ratios: inverse of the measured shading
        print(f'{k:>9} {G[j,i]:5.3f}  {Rn[j,i]/G[j,i]:5.3f}  {Bn[j,i]/G[j,i]:5.3f} | {1/G[j,i]:5.2f} R/G {G[j,i]/Rn[j,i]:5.3f} B/G {G[j,i]/Bn[j,i]:5.3f}'
              f' | {g6:5.2f} {r6:5.3f} {b6:5.3f} | {ga:5.2f} {ra:5.3f} {ba:5.3f}')
    np.savez(os.path.join(os.path.dirname(raws[0]), 'flatfield-grid.npz'), G=G, R=Rn, B=Bn)


if __name__ == '__main__':
    main()
