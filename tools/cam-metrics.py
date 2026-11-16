#!/usr/bin/env python3
"""
cam-metrics.py — picture-quality numbers for the enhanced-camera work (PLAN M1).

  cam-metrics.py PATH --regions R.json [--noise wall] [--face face]
                 [--frames 30] [--start 0]
                 [--ref REF.jpg --match-regions M.json --params P.env]
                 [--json OUT.json] [--overlay BOXES.png]

PATH is a still (.png/.jpg), a directory of stills (sorted, used as a sequence),
or a video file (.mkv/.nut/.mp4, decoded with ffmpeg).

R.json: {"name": [x0,y0,x1,y1] | {"frame": [x0,y0,x1,y1]}, ...} in fractions of
width/height. --noise names a flat, static patch (wall); --face names one or more
face boxes (comma list).

Metrics (all 8-bit units unless noted):
  noise_t_y / noise_t_c   temporal noise: RMS over the patch of the per-pixel
                          std-dev across N frames, luma (Y) and chroma (mean of
                          Cb, Cr). Needs >= 2 frames.  This is the PRD number.
  noise_s_y / noise_s_c   spatial stand-in: std-dev of (patch - Gaussian blur r=2)
                          on the first frame. Works on stills; NOT comparable to
                          noise_t, only to other noise_s values.
  face_lum                mean Y / 255 of the face box(es), averaged over frames.
  clip_pct                % of pixels (whole frame, averaged over frames) with
                          any channel >= 250.
  match_rms               match-reference.py "RMS now" against the phone photo
                          (first frame only; only with --ref).
Pure stdlib + Pillow (+ ffmpeg/ffprobe for video).
"""
import argparse, json, math, os, re, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter

def data(im):
    """Pixel list; get_flattened_data on Pillow >= 12, getdata before."""
    f = getattr(im, "get_flattened_data", None)
    return list(f() if f else im.getdata())


HERE = os.path.dirname(os.path.abspath(__file__))


def load_regions(path):
    out = {}
    for k, v in json.load(open(path)).items():
        if k.startswith("_"):
            continue
        out[k] = v["frame"] if isinstance(v, dict) else v
    return out


def box(size, f):
    w, h = size
    return (int(f[0] * w), int(f[1] * h), int(f[2] * w), int(f[3] * h))


def video_frames(path, start, n):
    pr = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                         "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
                        capture_output=True, text=True, check=True)
    w, h = map(int, pr.stdout.strip().split(",")[:2])
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-vf", f"select=gte(n\\,{start})",
           "-fps_mode", "passthrough", "-frames:v", str(n), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    fs = w * h * 3
    while True:
        b = p.stdout.read(fs)
        if len(b) < fs:
            break
        yield Image.frombytes("RGB", (w, h), b)
    p.wait()


def load_frames(path, start, n):
    if os.path.isdir(path):
        files = sorted(f for f in os.listdir(path) if f.lower().endswith((".png", ".jpg", ".jpeg")))
        return [Image.open(os.path.join(path, f)).convert("RGB") for f in files[start:start + n]]
    if path.lower().endswith((".png", ".jpg", ".jpeg")):
        return [Image.open(path).convert("RGB")]
    return list(video_frames(path, start, n))


def temporal_noise(frames, b):
    """RMS of per-pixel std-dev over frames, for Y and C (Cb, Cr averaged)."""
    n = len(frames)
    res = []
    for ch in range(3):
        s = s2 = None
        for im in frames:
            d = data(im.crop(b).convert("YCbCr").getchannel(ch))
            if s is None:
                s = [0.0] * len(d); s2 = [0.0] * len(d)
            for i, v in enumerate(d):
                s[i] += v; s2[i] += v * v
        var = [max(q / n - (p / n) ** 2, 0.0) * n / (n - 1) for p, q in zip(s, s2)]
        res.append(math.sqrt(sum(var) / len(var)))
    return res[0], (res[1] + res[2]) / 2


def spatial_noise(im, b):
    res = []
    crop = im.crop(b).convert("YCbCr")
    for ch in range(3):
        plane = crop.getchannel(ch)
        a = data(plane); c = data(plane.filter(ImageFilter.GaussianBlur(2)))
        r = [x - y for x, y in zip(a, c)]
        m = sum(r) / len(r)
        res.append(math.sqrt(sum((x - m) ** 2 for x in r) / len(r)))
    return res[0], (res[1] + res[2]) / 2


def face_lum(im, boxes):
    tot = cnt = 0
    for b in boxes:
        d = data(im.crop(b).convert("L"))
        tot += sum(d); cnt += len(d)
    return tot / cnt / 255


def clip_pct(im):
    small = im if im.width <= 960 else im.resize((im.width // 2, im.height // 2), Image.NEAREST)
    d = data(small)
    return 100 * sum(1 for p in d if max(p) >= 250) / len(d)


def match_rms(ref, frame_im, regions, params):
    tmp = "/tmp/cam-metrics-match.png"
    frame_im.save(tmp)
    only = {k: v for k, v in json.load(open(regions)).items() if isinstance(v, dict) and "ref" in v}
    rj = "/tmp/cam-metrics-match.json"
    json.dump(only, open(rj, "w"))
    r = subprocess.run([sys.executable, os.path.join(HERE, "match-reference.py"), ref, tmp,
                        "--regions", rj, "--params", params], capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stderr)
    m = re.search(r"RMS error \(8-bit\): now ([\d.]+)", r.stdout)
    return float(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path")
    ap.add_argument("--regions", required=True)
    ap.add_argument("--noise", default="wall")
    ap.add_argument("--face", default="face")
    ap.add_argument("--frames", type=int, default=30)
    ap.add_argument("--start", type=int, default=0, help="skip this many frames first")
    ap.add_argument("--ref"); ap.add_argument("--match-regions"); ap.add_argument("--params")
    ap.add_argument("--json", help="also write results here")
    ap.add_argument("--overlay", help="write the first frame with the noise/face boxes drawn (PNG)")
    a = ap.parse_args()

    regs = load_regions(a.regions)
    frames = load_frames(a.path, a.start, a.frames)
    if not frames:
        sys.exit("no frames decoded from " + a.path)
    size = frames[0].size
    nb = box(size, regs[a.noise])
    fb = [box(size, regs[k]) for k in a.face.split(",")]

    if a.overlay:
        ov = frames[0].copy(); d = ImageDraw.Draw(ov)
        for b, lab in [(nb, a.noise)] + [(b, "face") for b in fb]:
            d.rectangle(b, outline=(255, 0, 0), width=4); d.text((b[0] + 6, b[1] + 6), lab, fill=(255, 0, 0))
        ov.save(a.overlay)

    out = {"source": a.path, "resolution": f"{size[0]}x{size[1]}", "frames": len(frames)}
    if len(frames) >= 2:
        out["noise_t_y"], out["noise_t_c"] = temporal_noise(frames, nb)
    out["noise_s_y"], out["noise_s_c"] = spatial_noise(frames[0], nb)
    out["face_lum"] = sum(face_lum(im, fb) for im in frames) / len(frames)
    out["clip_pct"] = sum(clip_pct(im) for im in frames[:10]) / min(len(frames), 10)
    if a.ref:
        if not (a.match_regions and a.params):
            sys.exit("--ref needs --match-regions and --params")
        out["match_rms"] = match_rms(a.ref, frames[0], a.match_regions, a.params)

    for k, v in out.items():
        print(f"{k:11} {v:.3f}" if isinstance(v, float) else f"{k:11} {v}")
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
