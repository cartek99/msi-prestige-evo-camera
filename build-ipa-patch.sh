#!/bin/bash
# build-ipa-patch.sh — reproducibly rebuild the patched libcamera "simple" soft
# ISP IPA (ipa_soft_simple.so) from the Fedora source package of the installed
# libcamera, plus our IPA patches: patches/libcamera-0.7/0001-0003 and 0006 on
# libcamera 0.7.x (patches/0001-0002 on 0.5.x). Writes prebuilt/BUILT_FOR.
#
# This is how prebuilt/ipa_soft_simple.so was produced. You normally do NOT need
# to run this — apply-ipa-agc-patch.sh installs the prebuilt .so directly. Run
# this only to rebuild against a new libcamera release (bump VER below) or to
# audit the binary.
#
# Needs build deps once:  sudo dnf builddep -y libcamera
# Run (no sudo):          bash ~/ipu7-cam-fix/build-ipa-patch.sh
set -e
# Build against whatever libcamera is installed (source parity with the package).
VER=$(rpm -q --qf '%{version}' libcamera)
VR=$(rpm -q --qf '%{version}-%{release}' libcamera)
REPO=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/lc-build.XXXXXX)
echo "[1/5] Fetching libcamera-$VER source RPM"
cd "$WORK"
# Use a cached SRPM if present (dnf download can hang on a repo-key prompt — 2026-11-09)
if [ -f "$REPO/srpm-cache/libcamera-$VR.src.rpm" ]; then
    cp "$REPO/srpm-cache/libcamera-$VR.src.rpm" .
else
    timeout 300 dnf download -y --source "libcamera-$VR" </dev/null >/dev/null 2>&1
    mkdir -p "$REPO/srpm-cache"; cp libcamera-*.src.rpm "$REPO/srpm-cache/" 2>/dev/null || true
fi
rpm2cpio libcamera-*.src.rpm | cpio -idm >/dev/null 2>&1

echo "[2/5] Extracting + applying Fedora patch series (source parity with the installed package)"
tar xf libcamera-v$VER.tar.bz2
cd libcamera-v$VER
for p in "$WORK"/0*.patch; do patch -p1 -i "$p" >/dev/null; done

echo "[3/5] Applying the soft-ISP IPA patches (EV, manual AWB, Adjust defaults, EV follows light)"
# 0.7 reworked the AGC and renamed YamlObject -> ValueNode, so it has its own rebased series.
case "$VER" in
    0.5.*) PDIR="$REPO/patches" ;;
    0.7.*) PDIR="$REPO/patches/libcamera-0.7" ;;
    *)     echo "No patch series for libcamera $VER — rebase patches/libcamera-0.7 first."; exit 1 ;;
esac
patch -p1 -i "$PDIR/0001-ipa-simple-agc-exposure-value.patch"
patch -p1 -i "$PDIR/0002-ipa-simple-awb-manual-white-balance.patch"
# 0003 (0.7 only): Adjust reads gamma/contrast/saturation defaults from the tuning file
[ -f "$PDIR/0003-ipa-simple-adjust-tuning-defaults.patch" ] && patch -p1 -i "$PDIR/0003-ipa-simple-adjust-tuning-defaults.patch"
# 0006 (0.7 only, PLAN M4b): EV follows the scene light (tuning keys exposureValueBright/Dark, lightBright/Dark)
[ -f "$PDIR/0006-ipa-simple-agc-ev-follows-light.patch" ] && patch -p1 -i "$PDIR/0006-ipa-simple-agc-ev-follows-light.patch"

echo "[4/5] Configuring + building only the soft IPA (fast)"
meson setup build \
    -Dpipelines=simple -Dipas=simple -Dcam=disabled -Dqcam=disabled \
    -Dgstreamer=disabled -Dv4l2=disabled -Ddocumentation=disabled \
    -Dpycamera=disabled -Dlc-compliance=disabled -Dtest=false -Dtracing=disabled \
    >/dev/null
ninja -C build src/ipa/simple/ipa_soft_simple.so

echo "[5/5] Copying artifact into repo"
install -D -m 755 build/src/ipa/simple/ipa_soft_simple.so "$REPO/prebuilt/ipa_soft_simple.so"
echo "$VR" > "$REPO/prebuilt/BUILT_FOR"   # apply-ipa-agc-patch.sh refuses on mismatch
sha256sum "$REPO/prebuilt/ipa_soft_simple.so"
echo "Done. Install it with: sudo bash $REPO/apply-ipa-agc-patch.sh"
echo "(build tree left in $WORK — remove when done)"
