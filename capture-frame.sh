#!/bin/bash
# capture-frame.sh — grab a SETTLED frame from the Teams relay path
# (/dev/video0) to /tmp/cam-frame.png for color-tuning inspection.
# v2: single session, 90 frames (~3s) so AGC/AWB settle, keep the LAST frame
#     (v1 snapshotted the first frame of a cold camera = black).
# Run: bash ~/ipu7-cam-fix/capture-frame.sh   (no sudo)
set -e
rm -f /tmp/cam-seq-*.png /tmp/cam-frame.png
timeout 30 gst-launch-1.0 v4l2src device=/dev/video0 num-buffers=90 ! videoconvert \
    ! pngenc ! multifilesink location=/tmp/cam-seq-%03d.png >/dev/null 2>&1 || true
LAST=$(ls /tmp/cam-seq-*.png 2>/dev/null | tail -1)
if [ -n "$LAST" ] && [ -s "$LAST" ]; then
    mv "$LAST" /tmp/cam-frame.png
    rm -f /tmp/cam-seq-*.png
    echo "Settled frame saved: /tmp/cam-frame.png"
else
    echo "FAIL: no frames captured (relay running? journalctl -u v4l2-relayd@libcamerasrc)"
    exit 1
fi
