#!/bin/bash
# apply-ipa-agc-patch.sh — install the patched libcamera soft-ISP IPA (prebuilt/ipa_soft_simple.so,
# built by build-ipa-patch.sh) system-wide, so ALL consumers get it (relay, Snapshot, Firefox, qcam).
# On libcamera 0.7.2 it carries patches/libcamera-0.7/:
#   0001 AGC honours ExposureValue + a tuning default (the original fix for pink, clipped highlights)
#   0002 AWB manual / fixed white balance      0003 Adjust defaults from the tuning file
#   0006 the EV bias follows the scene light (used by the auto look)
# The tuning file itself is not touched: the installed look (cam-look) stays, and the relay restarts.
# Refuses to install if prebuilt/BUILT_FOR does not match the installed libcamera build.
#
# Idempotent. Backs up the stock IPA the first time. Run:
#   sudo bash ~/ipu7-cam-fix/apply-ipa-agc-patch.sh
#
# NOTE: the rebuilt IPA is not signed with Fedora's key, so libcamera loads it
# in an ISOLATED worker process (a documented, fully-supported mode — it does
# NOT disable the camera). A libcamera package update will overwrite it;
# check-cam-stack.sh [9] detects that — just re-run this script.
set -e
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
REPO=$(cd "$(dirname "$0")" && pwd)
SO=/usr/lib64/libcamera/ipa/ipa_soft_simple.so
SRC="$REPO/prebuilt/ipa_soft_simple.so"
BAK="$REPO/prebuilt/ipa_soft_simple.so.stock-$(rpm -q --qf '%{version}-%{release}' libcamera)"

[ -f "$SRC" ] || { echo "Missing $SRC — run build-ipa-patch.sh first."; exit 1; }

# Guard (2026-10-26, after the F44 upgrade took libcamera 0.5.2 -> 0.7.2): the
# prebuilt IPA only works with the exact libcamera it was compiled against.
# Installing a 0.5.2 .so on 0.7.2 breaks the camera for every app.
INSTALLED=$(rpm -q --qf '%{version}-%{release}' libcamera)
BUILT_FOR=$(cat "$REPO/prebuilt/BUILT_FOR" 2>/dev/null)
if [ "$INSTALLED" != "$BUILT_FOR" ]; then
    echo "REFUSING: prebuilt IPA was built for libcamera '$BUILT_FOR' but '$INSTALLED' is installed."
    echo "Rebuild it first (no sudo): bash $REPO/build-ipa-patch.sh"
    exit 1
fi

echo "[1/4] Backing up stock IPA (once per libcamera version)"
if [ ! -f "$BAK" ] && [ -f "$SO" ] && ! cmp -s "$SRC" "$SO"; then
    cp -a "$SO" "$BAK"
    [ -f "$SO.sign" ] && cp -a "$SO.sign" "$BAK.sign" || true
    echo "  saved $BAK"
else
    echo "  backup already present or nothing to back up — skipping"
fi

echo "[2/4] Installing patched IPA -> $SO"
install -m 755 "$SRC" "$SO"
# The stock signature no longer matches; remove it so libcamera cleanly treats
# the module as unsigned (isolated) instead of logging a signature mismatch.
rm -f "$SO.sign"

# Since 2026-11-10 the relay is libcamera-loopback and the tuning is chosen with cam-look
# (day|night|auto). The old step 3 ran apply-tuning.sh, which overwrote the look with the master
# yaml and restarted v4l2-relayd@libcamerasrc; that stopped libcamera-loopback (Conflicts=) and
# left the old relay crash-looping (2026-11-16). Only fall back to it on a v4l2-relayd system.
if systemctl cat libcamera-loopback >/dev/null 2>&1; then
    echo "[3/4] libcamera-loopback system: keeping the installed look ($(bash "$REPO/cam-look.sh" | sed 's/^installed look: //')), restarting the relay"
    systemctl restart libcamera-loopback
    systemctl is-active libcamera-loopback
else
    echo "[3/4] libcamera-loopback is not installed: install it (README step 2), then re-run this script"
    echo "      (the module is installed; apps that use libcamera directly already get it)"
fi

echo "[4/4] Verifying the patched IPA reads the tuning default"
sleep 1
if LIBCAMERA_LOG_LEVELS=IPASoftExposure:INFO timeout 8 \
     gst-launch-1.0 libcamerasrc camera-name='\\_SB_.LNK0' ! video/x-raw,width=1280,height=720 \
     ! fakesink num-buffers=15 2>&1 | grep -q -E "Default exposure value from tuning file|EV follows light"; then
    echo "  OK — patched IPA active and honoring exposureValue."
else
    echo "  WARN — did not see the tuning-default log line. Check with:"
    echo "    LIBCAMERA_LOG_LEVELS=IPASoftExposure:INFO gst-launch-1.0 libcamerasrc ! fakesink num-buffers=15"
fi
echo "Done. To revert to stock: sudo cp -a $BAK $SO; sudo cp -a $BAK.sign $SO.sign (then sudo systemctl restart libcamera-loopback)"
OLD="$REPO/prebuilt/ipa_soft_simple.so.0001-0003-0.7.2-3.fc45"
[ -f "$OLD" ] && echo "Previous patched IPA (0001-0003): $OLD" || true
