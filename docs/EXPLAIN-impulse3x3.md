# impulse3x3.frag, explained

The shader `shaders/impulse3x3.frag` (34 lines) removes salt-and-pepper speckle: single pixels that are
wrong for one frame. It runs on the GPU in the relay chain `v64x2i`, after VA-API denoise.

## The problem, in numbers
At night about 3156 pixels per 1080p frame (0.15%) were more than 20/255 off their neighbours' median
after VA denoise (measured 2026-11-11). Most of them change every frame, so they are random noise,
not dead pixels. They show up as grain on cheeks and walls.

## The method, in five steps
1. **Read the pixel and its 8 neighbours** (lines 17-27). `d` is the size of one pixel in texture
   coordinates (1/width, 1/height), because the GPU addresses the image from 0.0 to 1.0, not in pixels.
   `p0`..`p8` are the 3x3 block, top-left to bottom-right; `p4` is the centre.
2. **Find the median of the nine, per colour channel** (lines 28-31). `s2(a, b)` puts the smaller value
   in `a` and the larger in `b`. The 19 `s2` calls are a fixed "sorting network" that leaves the middle
   value (the 5th smallest of 9) in `p4`. This exact sequence is the published opt_med9 network
   (Paeth, Graphics Gems 1990; Devillard, "Fast median search", 1998).
   **Proof:** `python3 tools/check-median-network.py` (2026-11-19): all 512 zero/one inputs and 200,000 random inputs give the true
   median. The zero/one test alone is a complete proof for a sorting network.
3. **Measure how far off the centre pixel is** (line 32): the brightness (luma) of the difference between
   the original centre and the median. The weights 0.299 / 0.587 / 0.114 are the standard BT.601 luma
   weights.
4. **Replace only outliers** (line 33): if the difference is above `thresh`, output the median;
   otherwise output the original pixel. Flat areas, edges and anything 2+ pixels wide are left alone,
   because the median there equals the pixel. **Not** safe: a line exactly 1 pixel wide with contrast
   above 15/255 is erased (synthetic test 2026-11-19: 21 of 21 line pixels replaced; a 2-pixel line: 0;
   a 1-pixel line at contrast 4/255: 0). Eyelashes and stubble looked unchanged in our frames because
   after debayer and VA denoise they are wider than 1 pixel or lower in contrast.
5. **Keep alpha** unchanged (`c.a`).

## Every number and its source
| Value | Meaning | Source |
|---|---|---|
| 3x3 | smallest block with a centre | speckle is single pixels |
| 19 swaps | minimum known network for a median of 9 | Paeth 1990 / Devillard 1998 |
| thresh 0.06 (= 15/255) | how far off counts as speckle | sweep 2026-11-11 (night): 0.03 → 8 px/frame left, 0.06 → 17, 0.10 → 1667. Why 0.06 over 0.03 is not recorded; 0.03 also lowered overall noise (1.53 vs 1.61), a sign it starts smoothing real texture. Recheck before upstreaming |
| 0.299 / 0.587 / 0.114 | luma weights | ITU-R BT.601 |
| `highp` | 32-bit floats | `mediump` may be 16-bit on Mesa (precision loss) |

## Tests
`python3 tools/test-impulse-shader.py` runs the real shader on the GPU (GStreamer GL, same flattening as
cam-enhance.sh) over 14 synthetic cases with known answers, and compares each with a Python reference
model. Cases marked LIMIT pin the weaknesses below, so any change in behaviour shows up. 2026-11-19:
all pass at thresh 0.06 and 0.03, GPU = model on every pixel.

## Results
Night: 3156 → 17 speckle pixels per frame. Day: 836 → 34. Colour change 0.0-0.3%. Eyes, glasses edges and
stubble unchanged by eye.

## Limits (say these before a reviewer asks)
- **1-pixel lines and corners.** High-contrast lines exactly 1 pixel wide are erased, and the
  outermost corner pixel of a sharp shape is rounded off (synthetic test: 4 corner pixels of a 10x10
  square). Fine text at 1080p is the most likely victim. Not tested on real text.
- **Clumps only partly.** A median of 9 outvotes up to 4 bad pixels: a 2x2 clump is removed fully,
  a 3x2 clump only 4 of its 6 pixels.
- **Per-channel median.** R, G and B are sorted separately, so the output colour can be one that no
  neighbour had exactly. A "vector median" avoids this but costs more. Not seen as a problem by eye.
- **Colour-only speckle can slip through.** The test is on brightness, where blue weighs 0.114: a pixel
  77/255 too blue (and nothing else) is kept. Red-only at the same size is removed (0.299).
- **Image borders are fine** (verified 2026-11-19 on the GPU): edge pixels are repeated, and speckles on
  borders and corners are removed.
- **Cost not measured.** 9 texture reads and 19 min/max pairs per pixel; no timing taken.
- **Tuned after VA denoise, on gamma-encoded RGB.** Inside libcamera's soft ISP it would run at a
  different stage (no VA denoise in front), so the threshold would need a new sweep there.

## Not upstream-ready as is
Upstream would want it as a pass in the soft ISP GPU pipeline (see Bryan O'Donoghue's "gpuisp multipass"
RFC, series 6366, 2026-11-18), measured on soft ISP output alone.
