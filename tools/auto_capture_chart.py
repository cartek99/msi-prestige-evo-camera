#!/usr/bin/env python3
"""
auto_capture_chart.py — hands-off color-target capture.

Opens ONE continuous live preview window, counts down so you can hold the chart
steady, then automatically grabs several frames and closes by itself. You never
click anything — the window closing means it's done.

Exposure is fixed at start (libcamerasrc can't change it live). Default EV suits
most lighting; override with CC_EV if the white patch clips (lower, e.g. -1.5)
or the frame is too dark (higher, e.g. -0.5).

Invoked by auto-capture-chart.sh (sets calibration IPA env + pauses wireplumber).
Arg: output directory.
"""
import sys, os
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst, GLib

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
COUNTDOWN = int(os.environ.get("CC_COUNTDOWN", "20"))  # seconds to get steady
EV = float(os.environ.get("CC_EV", "-1.0"))            # fixed exposure bias
SINK = os.environ.get("CC_SINK", "waylandsink")        # fakesink for headless test
NSHOTS = int(os.environ.get("CC_SHOTS", "8"))          # frames to grab
GAP = float(os.environ.get("CC_GAP", "1.5"))           # seconds between grabs

Gst.init(None)

pipeline = Gst.parse_launch(
    f"libcamerasrc name=src exposure-value={EV} saturation=1.0 contrast=1.0 "
    "! video/x-raw,format=RGBx,width=1280,height=720 ! tee name=t "
    f"t. ! queue leaky=downstream max-size-buffers=3 ! videoconvert ! {SINK} sync=false "
    "t. ! queue leaky=downstream max-size-buffers=3 ! videoconvert "
    "   ! video/x-raw,format=RGB ! appsink name=grab emit-signals=false max-buffers=2 drop=true"
)
src = pipeline.get_by_name("src")
grab = pipeline.get_by_name("grab")
loop = GLib.MainLoop()

def save_frame(name):
    sample = grab.emit("try-pull-sample", Gst.SECOND)
    if not sample:
        print(f"  (no frame for {name})"); return
    buf = sample.get_buffer()
    st = sample.get_caps().get_structure(0)
    w, h = st.get_value("width"), st.get_value("height")
    ok, mi = buf.map(Gst.MapFlags.READ)
    if not ok:
        return
    try:
        from PIL import Image
        Image.frombytes("RGB", (w, h), bytes(mi.data[: w * h * 3])).save(
            os.path.join(OUT, name))
        print(f"  saved {name}")
    finally:
        buf.unmap(mi)

state = {"t": 0, "shot": 0}

def tick():
    left = COUNTDOWN - state["t"]
    if left in (20, 15, 10, 5, 4, 3, 2, 1):
        print(f"Hold the FULL chart steady in the window — capturing in {left}s…")
    state["t"] += 1
    if left <= 0:
        print(f"Capturing {NSHOTS} frames (EV={EV}) — keep still…")
        GLib.timeout_add(int(GAP * 1000), shoot)
        return False
    return True

def shoot():
    save_frame(f"chart-{state['shot']:02d}.png")
    state["shot"] += 1
    if state["shot"] >= NSHOTS:
        print("Done — closing preview.")
        pipeline.set_state(Gst.State.NULL)
        loop.quit()
        return False
    return True   # keep firing every GAP seconds

def on_msg(bus, msg):
    if msg.type == Gst.MessageType.ERROR:
        err, _ = msg.parse_error()
        print("ERROR:", err.message)
        pipeline.set_state(Gst.State.NULL); loop.quit()

bus = pipeline.get_bus(); bus.add_signal_watch(); bus.connect("message", on_msg)

pipeline.set_state(Gst.State.PLAYING)
print("Preview open. Hold the full 24-patch chart in the window "
      "(it looks green — that's normal for calibration).")
GLib.timeout_add_seconds(1, tick)
try:
    loop.run()
except KeyboardInterrupt:
    pipeline.set_state(Gst.State.NULL)
