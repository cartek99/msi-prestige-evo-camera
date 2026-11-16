#!/usr/bin/env python3
"""gst-denoise-sweep.py — PLAN M4a offline sweep of the relay's own GStreamer chains. No sudo, no camera.

  python3 tools/gst-denoise-sweep.py STILL.mkv WAVE.mkv REGIONS.json TAG [--start 30] [--n 60]

Each candidate is a cam-enhance.sh mode (taken from `cam-enhance.sh --print MODE`, so the sweep
runs the exact string the relay would run) with the libcamerasrc head swapped for a file decoder,
plus a few variants. For each: filter STILL and WAVE through Gst.parse_launch (as the relay
does) into samples/clips/gproto-TAG-<name>-{still,wave}.mkv, then report
  noise_t_y, noise_s_y/c, face_lum   tools/cam-metrics.py
  speckle px/frame                   pixels whose luma differs >20 from their 3x3 median (impulse noise)
  colour dmax %                      largest |change| of region mean Y, R/G, B/G vs the v64x2 baseline
  ghost moving/static                tools/ghost-metric.py on WAVE (input vs output)
  CPU ms/frame                       process CPU time vs the v64x2 run (signed; offline only a rough
                                     guide: decode/encode dominate, so measure the live relay too)
Writes samples/clips/gproto-TAG-results.md and gproto-TAG-sheet.png (face crop, 2x zoom).
"""
import argparse, json, os, re, resource, subprocess, sys, time

import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst
from PIL import Image, ImageChops, ImageFilter, ImageStat

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "samples", "clips")


def mode(m):
    s = subprocess.run(["bash", os.path.join(REPO, "cam-enhance.sh"), "--print", m],
                       capture_output=True, text=True, check=True).stdout.strip()
    # drop "libcamerasrc ... ! video/x-raw,...framerate=30/1": the file decoder replaces it
    return re.sub(r"^libcamerasrc[^!]*! video/x-raw[^!]*", "", s).lstrip("! ").strip()


def candidates():
    v64x2, v64x2i, v64i = mode("v64x2"), mode("v64x2i"), mode("v64i")
    t = lambda chain, v: chain.replace("thresh=(float)0.06", f"thresh=(float){v}")
    return [
        ("none", "identity"),
        ("v64x2", v64x2),
        ("v64x2i", v64x2i),                      # threshold 0.06 (15/255)
        ("v64x2i-t03", t(v64x2i, "0.03")),
        ("v64x2i-t10", t(v64x2i, "0.10")),
        ("v64i", v64i),
        ("v64x2-med5cpu", v64x2 + " ! videoconvert ! video/x-raw,format=I420 ! videomedian filtersize=5"),
    ]


def run(src, chain, dst):
    desc = (f"filesrc location={src} ! matroskademux ! avdec_ffv1 ! videoconvert ! "
            f"video/x-raw,format=NV12 ! {chain} ! video/x-raw,width=1920,height=1080 ! "
            f"videoconvert ! video/x-raw,format=Y42B ! avenc_ffv1 ! matroskamux ! filesink location={dst}")
    r0 = resource.getrusage(resource.RUSAGE_SELF)
    p = Gst.parse_launch(desc)
    p.set_state(Gst.State.PLAYING)
    msg = p.get_bus().timed_pop_filtered(600 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
    p.set_state(Gst.State.NULL)
    r1 = resource.getrusage(resource.RUSAGE_SELF)
    if msg is None or msg.type == Gst.MessageType.ERROR:
        raise RuntimeError(f"{dst}: {msg.parse_error() if msg else 'timeout'}")
    return (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)


def gray_frames(path, start, n):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"select=gte(n\\,{start}),format=gray",
                          "-frames:v", str(n), "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    sz = 1920 * 1080
    return [Image.frombytes("L", (1920, 1080), raw[i * sz:(i + 1) * sz]) for i in range(len(raw) // sz)]


def speckle(path, start, n=20):
    fr = gray_frames(path, start, n)
    tot = 0
    for f in fr:
        d = ImageChops.difference(f, f.filter(ImageFilter.MedianFilter(3))).point(lambda v: 1 if v > 20 else 0)
        tot += d.histogram()[1]
    return tot / max(len(fr), 1)


def colour(path, regions, frame):
    tmp = "/tmp/gsweep-colour.png"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-vf", f"select=eq(n\\,{frame})",
                    "-frames:v", "1", tmp], check=True)
    im = Image.open(tmp).convert("RGB")
    W, H = im.size
    out = {}
    for k, b in regions.items():
        if k.startswith("_"):
            continue
        b = b["frame"] if isinstance(b, dict) else b
        r, g, bl = ImageStat.Stat(im.crop((int(b[0] * W), int(b[1] * H), int(b[2] * W), int(b[3] * H)))).mean
        out[k] = (0.299 * r + 0.587 * g + 0.114 * bl, r / g, bl / g)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("still"); ap.add_argument("wave"); ap.add_argument("regions"); ap.add_argument("tag")
    ap.add_argument("--start", type=int, default=30)
    ap.add_argument("--n", type=int, default=60)
    ap.add_argument("--only", help="comma list of candidate names")
    a = ap.parse_args()
    Gst.init(None)
    regions = json.load(open(a.regions))
    cands = candidates()
    if a.only:
        keep = set(a.only.split(",")) | {"none", "v64x2"}
        cands = [c for c in cands if c[0] in keep]
    nframes = int(subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
                                  "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", a.still],
                                 capture_output=True, text=True).stdout.strip() or 300)
    res_md = os.path.join(OUT, f"gproto-{a.tag}-results.md")
    rows, base_cpu, base_col = [], None, None
    for name, chain in cands:
        still = os.path.join(OUT, f"gproto-{a.tag}-{name}-still.mkv")
        wave = os.path.join(OUT, f"gproto-{a.tag}-{name}-wave.mkv")
        try:
            cpu = run(a.still, chain, still)
            run(a.wave, chain, wave)
        except Exception as e:  # keep sweeping; report the failure in the table
            print(f"{name}: FAILED {e}", file=sys.stderr)
            rows.append(f"| {name} | FAILED: {str(e)[:120]} |||||||")
            continue
        if name == "v64x2":
            base_cpu = cpu
        m = subprocess.run([sys.executable, os.path.join(REPO, "tools", "cam-metrics.py"), still,
                            "--regions", a.regions, "--frames", "30", "--start", str(a.start)],
                           capture_output=True, text=True).stdout
        mv = dict(l.split()[:2] for l in m.splitlines() if len(l.split()) >= 2)
        g = subprocess.run([sys.executable, os.path.join(REPO, "tools", "ghost-metric.py"), a.wave, wave,
                            "--frames", str(a.n)], capture_output=True, text=True).stdout.split()
        col = colour(still, regions, a.start + 15)
        if name == "v64x2":
            base_col = col
        dmax = "–"
        if base_col and name != "none":
            dmax = f"{max(abs(c / b - 1) * 100 for k in col for c, b in zip(col[k], base_col[k])):.1f}"
        ms = f"{(cpu - base_cpu) * 1000 / nframes:+.1f}" if base_cpu is not None else "–"
        sp = speckle(still, a.start)
        f = lambda k: f"{float(mv[k]):.2f}" if k in mv else "?"
        row = (f"| {name} | {f('noise_t_y')} | {f('noise_s_y')} / {f('noise_s_c')} | {sp:.0f} | {f('face_lum')} "
               f"| {dmax} | {g[1] if len(g) > 3 else '?'} / {g[3] if len(g) > 3 else '?'} | {ms} |")
        print(row, flush=True)
        rows.append(row)
    with open(res_md, "w") as fh:
        fh.write(f"# GStreamer denoise sweep {a.tag} ({time.strftime('%F %T')})\n")
        fh.write(f"still `{os.path.basename(a.still)}`, wave `{os.path.basename(a.wave)}`; metrics from frame {a.start}. "
                 "Chains = `cam-enhance.sh --print MODE` with a file decoder instead of libcamerasrc. "
                 "colour dmax = largest |change| of region mean Y, R/G, B/G vs v64x2. CPU = process CPU vs the v64x2 run (rough; measure live).\n\n")
        fh.write("| chain | noise_t_y | noise_s Y/C | speckle px/frame | face_lum | colour dmax % | ghost mov/static | CPU ms/frame |\n")
        fh.write("|---|---|---|---|---|---|---|---|\n")
        fh.write("\n".join(rows) + "\n\n")
        for name, chain in cands:
            fh.write(f"- **{name}**: `{chain[:200]}{'…' if len(chain) > 200 else ''}`\n")
    face = regions.get("face", [0.455, 0.575, 0.545, 0.655])
    face = face["frame"] if isinstance(face, dict) else face
    cx, cy = (face[0] + face[2]) / 2 * 1920, (face[1] + face[3]) / 2 * 1080
    box = f"{int(cx - 200)},{int(cy - 160)},{int(cx + 200)},{int(cy + 80)}"
    clips = [f"{n}={os.path.join(OUT, f'gproto-{a.tag}-{n}-still.mkv')}" for n, _ in cands
             if os.path.exists(os.path.join(OUT, f"gproto-{a.tag}-{n}-still.mkv"))]
    subprocess.run([sys.executable, os.path.join(REPO, "tools", "contact-sheet.py"),
                    os.path.join(OUT, f"gproto-{a.tag}-sheet.png"), *clips,
                    "--frame", str(a.start + 15), "--box", box, "--cols", "2", "--zoom", "2"], check=True)
    print(f"results: {res_md}")


if __name__ == "__main__":
    main()
