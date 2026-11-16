#!/usr/bin/python3 -I
"""Test the relay's failure handling (local patches 0002 + 0004) without a camera or loopback device.
Runs the vendored Relay's start/error/watchdog/fallback code against /dev/null with videotestsrc.
    python3 -I tools/test-relay-fallback.py
Cases: start-up failures (missing element, unlinkable caps, runtime bus error, no first frame),
a mid-stream stall, a healthy source, no fallback set, give-up when everything fails,
and a fresh open retrying the enhanced chain after a fallback."""
import importlib.util, os, sys, types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# The relay source: the vendored copy, or set LOOPBACK_PY to libcamera-loopback.py in a checkout of
# https://github.com/alanbato/libcamera-loopback (v0.1.0) with patches/libcamera-loopback applied.
spec = importlib.util.spec_from_file_location(
    "relay", os.environ.get("LOOPBACK_PY", REPO / "third_party/libcamera-loopback/libcamera-loopback.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
from gi.repository import GLib, Gst  # noqa: E402  (imported by the relay module)

Gst.init(None)
relay.FIRST_FRAME_S = 2
relay.STALL_S = 1
LOG = []
relay.log = lambda *a: LOG.append(" ".join(str(x) for x in a))
GOOD = "videotestsrc is-live=true"
BROKEN = "videotestsrc is-live=true ! nosuchelement_xyz"
W, H, FPS = 320, 240, 30


def make(source, fallback):
    r = relay.Relay.__new__(relay.Relay)          # skip __init__ (no device, no D-Bus)
    r.a = types.SimpleNamespace(source=source, stats=0, linger=0, device="/dev/null")
    r.w, r.h, r.fps, r.pixfmt = W, H, FPS, "YUY2"
    r.frame_size, r.bpl = W * H * 2, W * 2
    r.pipeline, r.frames, r.stop_timer, r.st = None, 0, 0, None
    r.readers, r.sleeping = 1, False
    r.primary, r.source, r.fallback = source, source, fallback
    r.failures, r.last_frame = [], 0.0
    r.fd = os.open("/dev/null", os.O_WRONLY)
    return r


def spin(seconds):
    loop = GLib.MainLoop()
    GLib.timeout_add(int(seconds * 1000), loop.quit)
    loop.run()


def run(source, fallback, seconds=4.5):
    LOG.clear()
    r = make(source, fallback)
    r.start()
    spin(seconds)
    alive = r.pipeline is not None and r.frames > 0
    used = r.source
    r.stop()
    return used, alive, list(LOG)


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{': ' + detail if detail else ''}")
    return not ok


fails = 0
for name, src in [
    ("missing element", BROKEN),
    ("caps won't link (parse)", "videotestsrc is-live=true ! video/x-raw,width=99,height=7 ! identity"),
    ("runtime bus error", "filesrc location=/nonexistent/x ! rawvideoparse width=320 height=240 "
                          "format=yuy2 framerate=30/1"),
    ("no first frame", "videotestsrc is-live=true pattern=black ! valve drop=true"),
    ("stall mid-stream", "videotestsrc is-live=true num-buffers=30"),   # 1 s of frames, then nothing
]:
    used, alive, _ = run(src, GOOD)
    fails += check(name, used == GOOD and alive, f"fallback={used == GOOD} streaming={alive}")

used, alive, _ = run(GOOD, "videotestsrc is-live=true pattern=ball")
fails += check("healthy source stays", used == GOOD and alive)

used, alive, _ = run(BROKEN, "", seconds=1)
fails += check("no fallback set", used == BROKEN and not alive)

used, alive, log = run(BROKEN, "videotestsrc ! nosuchelement_abc", seconds=2)
gave_up = any(l.startswith("giving up") for l in log)
starts = sum(l.startswith("starting:") for l in log)
fails += check("everything broken: gives up, no loop", gave_up and not alive and starts <= 4,
               f"starts={starts} gave_up={gave_up}")

used, alive, log = run("videotestsrc is-live=true num-buffers=15", "", seconds=9)
restarts = sum(l == "restarting the same source" for l in log)
fails += check("stall, no fallback: restarts then gives up",
               restarts >= 1 and any(l.startswith("giving up") for l in log),
               f"restarts={restarts}")

LOG.clear()
r = make(BROKEN, GOOD)
r.start()
spin(1)
on_fallback = r.source == GOOD
r.stop()
r.start()      # a new reader = fresh start
retried = any(l.startswith("starting: " + BROKEN) for l in LOG[-6:])
spin(1)
r.stop()
fails += check("fresh open retries the enhanced chain", on_fallback and retried,
               f"was on fallback={on_fallback} retried primary={retried}")
sys.exit(1 if fails else 0)
