#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build a libcamera softisp tuning file for the OV5675 from an Intel AIQB.

Reads, from the AIQB of the Windows camera driver (Lunar Lake / IPU7 layout,
checked on OV5675_BCAB65_LNL.aiqb from MSI's Camera_LNL_17232 package):
  record 25  advanced colour matrices: per light source the CCT, the sensor
             white point (R/G, B/G) and the traditional 3x3 CCM (rows sum 1)
  record 28  lens shading 4x4: per light source a 63x47 grid per Bayer
             channel, Q11 (2048 = 1.0), channels by grid_indices (GRBG)
and writes Awb (bayes, gains = inverse white point, flat priors), Lsc (17x17,
UQ2.6 bytes, 64 = 1.0, max 255), Ccm, plus the AGC constraints kept from the
current tuning file. The lens shading sets are matched to the colour matrix
sources by light-source type, so all three share one CCT axis.

Usage: aiqb-to-softisp.py AIQB OUT.yaml [--lsc-strength 1.0] [--lsc-luma-only]
       [--transverse-neg 0.05] [--drop-ct 2717] [--no-lsc]
"""

import argparse
import os
import struct
import sys

# Layouts follow ia_cmc_types.h (intel/ipu7-camera-bins, include/ipu7x/ia_imaging).
REC_HDR = struct.Struct('<IBBH')   # ia_mkn_record_header: size, format id, key id, name id (cmc_name_id)
FIRST_RECORD = 0x50                # the record chain starts after the file header in every blob seen
ACM_ID, LSC_ID = 25, 28            # cmc_name_id_advanced_color_matrices, _lens_shading_correction_4x4
GRID = 17                          # DebayerParams::kLscGridSize of the software ISP


def records(data):
    """Walk the record chain and return {name_id: (offset, size)}.

    Each record starts with its total size, so the walk hops from record to record and stops
    at the first header that is not plausible (the tail of the file holds other sections).
    """
    out, off = {}, FIRST_RECORD
    while off + 8 <= len(data):
        size, _, _, name = REC_HDR.unpack_from(data, off)
        if size < 8 or off + size > len(data):
            break
        out[name] = (off, size)
        off += size
    return out


def read_acm(data, off, size):
    """Parse record 25 (advanced colour matrices) into one dict per light source.

    After the 8-byte header: light-source count, sector count, one hue per sector, then per
    light source the 24-byte info (source type, sensor white point R/G and B/G, CIE x/y, CCT in
    K), the 3x3 'traditional' CCM (9 floats, rows sum to 1), and one CCM per hue sector. The
    sector matrices are skipped: the software ISP applies one CCM per colour temperature.
    """
    p = off + 8
    n, sectors = struct.unpack_from('<HH', data, p)
    p += 4 + 4 * sectors
    out = []
    for _ in range(n):
        src, rg, bg, _, _, cct = struct.unpack_from('<IffffI', data, p)
        ccm = struct.unpack_from('<9f', data, p + 24)
        p += 24 + 36 + 36 * sectors
        out.append(dict(src=src, cct=cct, rg=rg, bg=bg, ccm=ccm))
    assert p <= off + size, 'record 25 overrun'
    return out


def read_lsc(data, off, size):
    """Parse record 28 (lens shading 4x4) into ({source type: [grid per channel]}, cell, w, h).

    After the 8-byte header: a 4x4 table of grid indices per Bayer position (-1 = unused; a 2x2
    sensor uses the top-left 2x2), light-source count, grid count, grid width and height. Each
    light source has a 22-byte header (source type, a pair index, white point, CIE x/y, fraction
    bits) and one uint16 grid per channel, row-major. Values are Q11 (2048 = gain 1.0) in this
    blob; the grids span the full sensor, edge to edge.
    """
    p = off + 8
    idx = struct.unpack_from('<16b', data, p)
    p += 16
    n, ngrids, w, h = struct.unpack_from('<4H', data, p)
    p += 8
    # 2x2 Bayer cell of the 4x4 index table: rows 0 and 1, columns 0 and 1
    cell = {(0, 0): idx[0], (0, 1): idx[1], (1, 0): idx[4], (1, 1): idx[5]}
    out = {}
    for _ in range(n):
        src = struct.unpack_from('<H', data, p)[0]
        p += 22
        grids = []
        for _ in range(ngrids):
            grids.append(struct.unpack_from(f'<{w * h}H', data, p))
            p += 2 * w * h
        out[src] = grids
    assert p <= off + size, 'record 28 overrun'
    return out, cell, w, h


def bilinear(g, w, h, u, v):
    """Sample the row-major w x h grid g at fractional position (u, v), both 0..1 edge to edge."""
    x, y = u * (w - 1), v * (h - 1)
    x0, y0 = int(x), int(y)
    x1, y1 = min(x0 + 1, w - 1), min(y0 + 1, h - 1)
    fx, fy = x - x0, y - y0
    a = g[y0 * w + x0] * (1 - fx) + g[y0 * w + x1] * fx
    b = g[y1 * w + x0] * (1 - fx) + g[y1 * w + x1] * fx
    return a * (1 - fy) + b * fy


def resample(g, w, h, strength):
    """Convert one vendor grid to the software ISP's 17x17 table.

    Samples the grid at the 17x17 positions (edge to edge, like libipa's grid), divides by the
    centre value so the centre gain is exactly 1.0, optionally scales the correction towards
    1.0 (strength < 1), and quantises to UQ2.6 bytes (64 = 1.0). Gains above 255/64 = 3.98 are
    clipped; the count of clipped cells and the peak gain are returned for the report.
    """
    centre = bilinear(g, w, h, 0.5, 0.5)
    vals, clipped, peak = [], 0, 0.0
    for j in range(GRID):
        for i in range(GRID):
            gain = bilinear(g, w, h, i / (GRID - 1), j / (GRID - 1)) / centre
            gain = 1.0 + (gain - 1.0) * strength
            peak = max(peak, gain)
            q = round(gain * 64)
            if q > 255:
                q, clipped = 255, clipped + 1
            vals.append(q)
    return vals, clipped, peak


def fmt_table(name, vals):
    """Format a 17x17 table as a YAML flow list, one grid row per line."""
    rows = [', '.join(f'{v:3d}' for v in vals[r * GRID:(r + 1) * GRID])
            for r in range(GRID)]
    body = ',\n'.join(f'            {r}' for r in rows)
    return f'          {name}: [\n{body}\n          ]\n'


def main():
    """Read the blob, pair each colour-matrix source with its shading grid, write the YAML.

    The colour temperature axis is taken from record 25 (the CCT Intel measured for each
    source); record 28 has no CCT, so its grids are matched by light-source type. Every CCM is
    checked to keep white (rows sum to 1) before anything is written.
    """
    ap = argparse.ArgumentParser()
    ap.add_argument('aiqb')
    ap.add_argument('out')
    ap.add_argument('--lsc-strength', type=float, default=1.0,
                    help='1.0 = full vendor correction, 0 = none')
    ap.add_argument('--drop-ct', type=int, action='append', default=[],
                    help='leave out the light source with this CCT')
    ap.add_argument('--no-lsc', action='store_true')
    ap.add_argument('--lsc-luma-only', action='store_true',
                    help='same gain for R, G and B (vignetting only, no colour shading)')
    ap.add_argument('--transverse-neg', type=float, default=None,
                    help='bayes search distance off the CT curve towards green (default 0.01)')
    ap.add_argument('--transverse-pos', type=float, default=None,
                    help='bayes search distance off the CT curve towards magenta (default 0.01)')
    a = ap.parse_args()

    data = open(a.aiqb, 'rb').read()
    rec = records(data)
    acm = [m for m in read_acm(data, *rec[ACM_ID]) if m['cct'] not in a.drop_ct]
    acm.sort(key=lambda m: m['cct'])
    lsc, cell, w, h = read_lsc(data, *rec[LSC_ID])
    # GRBG: (0,0)=Gr (0,1)=R (1,0)=B (1,1)=Gb
    ch = dict(Gr=cell[(0, 0)], R=cell[(0, 1)], B=cell[(1, 0)], Gb=cell[(1, 1)])

    for m in acm:
        rows = [sum(m['ccm'][r * 3:r * 3 + 3]) for r in range(3)]
        assert all(abs(s - 1) < 0.01 for s in rows), (m['cct'], rows)
        assert m['src'] in lsc, f"no lens shading grid for source {m['src']}"

    cts = [m['cct'] for m in acm]
    prob = round(1 / len(cts), 6)
    o = []
    o.append('# SPDX-License-Identifier: CC0-1.0\n')
    o.append('# Calibrated from the AIQB of the Windows camera driver of the MSI Prestige 13\n'
             f'# AI+ Evo A2VMG ({os.path.basename(a.aiqb)}). The colour gains, lens\n'
             '# shading tables and colour matrices come from the same light sources, so\n'
             '# they share one colour temperature axis.\n')
    o.append('%YAML 1.1\n---\nversion: 1\nalgorithms:\n  - BlackLevel:\n')
    o.append('  - Awb:\n      algorithm: bayes\n')
    o.append('      # Each gain is the inverse of the calibrated white point of its light\n'
             '      # source. Flat priors: no illuminant statistics for this module.\n')
    o.append('      colourGains:\n')
    for m in acm:
        o.append(f"        - ct: {m['cct']}\n          gains: [ {1 / m['rg']:.5f}, {1 / m['bg']:.5f} ]\n")
    o.append('      priors:\n')
    for lux in (0, 100):
        o.append(f'        - lux: {lux}\n          ct: [ {", ".join(map(str, cts))} ]\n')
        o.append(f'          probability: [ {", ".join([str(prob)] * len(cts))} ]\n')
    if a.transverse_neg is not None:
        o.append('      # LED room lighting sits on the green side of the calibrated sources\n'
                 '      # (0.044 in R/G, B/G under a warm white LED); the default 0.01 leaves\n'
                 '      # a yellow-green cast.\n')
        o.append(f'      transverseNeg: {a.transverse_neg}\n')
    if a.transverse_pos is not None:
        o.append(f'      transversePos: {a.transverse_pos}\n')
    o.append(f'      AwbMode:\n        Auto:\n          lo: {cts[0] - 200}\n          hi: {cts[-1] + 500}\n')

    report = []
    if not a.no_lsc:
        o.append('  - Lsc:\n'
                 '      # The 63x47 vendor grids resampled to 17x17 and normalised on the\n'
                 '      # centre. The corners need x4.1-4.9; cells above 3.98 are clipped.\n')
        if a.lsc_luma_only:
            o.append('      # Luminance only: the averaged green grid is used for all three\n'
                     '      # channels. The vendor colour shading (a few percent at the edges)\n'
                     '      # turns the edges yellow under warm LED light through the low\n'
                     '      # colour temperature matrices.\n')
        o.append('      type: table\n      sets:\n')
        for m in acm:
            g = lsc[m['src']]
            r, cr, pr = resample(g[ch['R']], w, h, a.lsc_strength)
            b, cb, pb = resample(g[ch['B']], w, h, a.lsc_strength)
            gavg = [(x + y) / 2 for x, y in zip(g[ch['Gr']], g[ch['Gb']])]
            gg, cg, pg = resample(gavg, w, h, a.lsc_strength)
            if a.lsc_luma_only:
                r, b, cr, cb, pr, pb = gg, gg, cg, cg, pg, pg
            report.append(f"  lsc ct {m['cct']} (src {m['src']}): peak R {pr:.2f} G {pg:.2f} B {pb:.2f}, "
                          f"clipped cells R {cr} G {cg} B {cb}")
            o.append(f"        - ct: {m['cct']}\n")
            o.append(fmt_table('r', r) + fmt_table('g', gg) + fmt_table('b', b))

    o.append('  - Ccm:\n'
             '      # The traditional colour matrices of the vendor calibration, copied\n'
             '      # as they are; every row sums to 1.\n'
             '      ccms:\n')
    for m in acm:
        c = m['ccm']
        o.append(f"        - ct: {m['cct']}\n")
        o.append(f'          ccm: [ {c[0]:8.5f}, {c[1]:8.5f}, {c[2]:8.5f},\n')
        o.append(f'                 {c[3]:8.5f}, {c[4]:8.5f}, {c[5]:8.5f},\n')
        o.append(f'                 {c[6]:8.5f}, {c[7]:8.5f}, {c[8]:8.5f} ]\n')
        o.append('          offsets: [ 0, 0, 0 ]\n')
    o.append('  - Adjust:\n')
    o.append('''  - Agc:
      AeConstraintMode:
        Normal:
          # The default constraint: the brightest 2% at least 0.5.
          lower:
            qLo: 0.98
            qHi: 1.0
            yTarget: 0.5
          # Limit highlight clipping: the brightest 2% at most 0.9.
          upper:
            qLo: 0.98
            qHi: 1.0
            yTarget: 0.9
...
''')
    open(a.out, 'w').write(''.join(o))
    print(f'wrote {a.out}: cts {cts}, lsc strength {a.lsc_strength}')
    print('\n'.join(report))


if __name__ == '__main__':
    sys.exit(main())
