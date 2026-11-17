#!/bin/bash
# STATUS: PARKED — builds the private libcamera of PLAN M3 (off since 2026-11-11). See README.md.
# build-libcamera-private.sh — build the private libcamera for the relay (PLAN M3). No sudo.
#   bash build-libcamera-private.sh          build + stage into ~/.cache/ipu7-cam/lc-build/stage
#   sudo bash install-cam-tools.sh           then copies the staged tree to /opt/libcamera-ae
# Same source as the installed package (cached SRPM + Fedora patch series), plus our patches:
#   0001-0003 IPA (EV, manual AWB, Adjust defaults; the same ones as the system prebuilt IPA)
#   0004 core: centre-weighted AE histogram   (env LIBCAMERA_SOFTISP_AE_WINDOW=x,y,w,h[,weight])
#   0005 IPA:  AGC highlight guard            (tuning Agc: highlightGuard, highlightLevel)
# Self-contained under /opt/libcamera-ae: libcamera.so, the signed simple IPA (loads in-process),
# the GStreamer plugin (libcamerasrc) and cam. Fedora compiler flags; GPU debayer is REQUIRED
# (-Dsoftisp-gpu=enabled: a missing EGL dev package fails the build instead of silently falling
# back to the CPU debayer). The tuning file is a symlink to the system one, so cam-look keeps
# working even if LIBCAMERA_IPA_CONFIG_PATH is lost.
set -eu
REPO=$(cd "$(dirname "$0")" && pwd)
PREFIX=/opt/libcamera-ae
VR=$(rpm -q --qf '%{version}-%{release}' libcamera)
VER=$(rpm -q --qf '%{version}' libcamera)
SRPM=$REPO/srpm-cache/libcamera-$VR.src.rpm
PDIR=$REPO/patches/libcamera-0.7
WORK=$HOME/.cache/ipu7-cam/lc-build
PATCHES="0001-ipa-simple-agc-exposure-value 0002-ipa-simple-awb-manual-white-balance
         0003-ipa-simple-adjust-tuning-defaults 0004-softisp-stats-ae-window
         0005-ipa-simple-agc-highlight-guard"
[ -f "$SRPM" ] || { echo "missing $SRPM (system libcamera is $VR)"; exit 1; }
for p in $PATCHES; do [ -f "$PDIR/$p.patch" ] || { echo "missing $PDIR/$p.patch"; exit 1; }; done
pkg-config --exists gstreamer-1.0 gstreamer-video-1.0 gstreamer-allocators-1.0 egl glesv2 \
    || { echo "missing dev packages: sudo dnf builddep -y libcamera"; exit 1; }

echo "[1/5] Source: libcamera $VR + Fedora patches + ours"
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
rpm2cpio "$SRPM" | cpio -idm 2>/dev/null
tar xf "libcamera-v$VER.tar.bz2"
cd "libcamera-v$VER"
for p in "$WORK"/0*.patch; do patch -p1 -s -i "$p"; done
for p in $PATCHES; do patch -p1 -s -i "$PDIR/$p.patch"; done

echo "[2/5] Configure (prefix $PREFIX, Fedora flags, GPU debayer required)"
export CFLAGS="$(rpm --eval '%{optflags}') -Wno-deprecated-declarations"
export CXXFLAGS="$(rpm --eval '%{optflags}') -Wno-deprecated-declarations --param=max-devirt-targets=1"
# rpath: the private plugin/cam always bind the private libcamera.so, never a mix (red team R4)
export LDFLAGS="$(rpm --eval '%{build_ldflags}') -Wl,-rpath,$PREFIX/lib64"
meson setup build --prefix="$PREFIX" --libdir=lib64 -Dbuildtype=plain \
    -Dpipelines=simple -Dipas=simple -Dsoftisp-gpu=enabled \
    -Dgstreamer=enabled -Dcam=enabled -Dqcam=disabled -Dv4l2=disabled \
    -Ddocumentation=disabled -Dpycamera=disabled -Dlc-compliance=disabled \
    -Dtest=false -Dtracing=disabled -Dlibunwind=disabled > "$WORK/meson-setup.log" 2>&1 \
    || { tail -30 "$WORK/meson-setup.log"; exit 1; }
grep -q "SoftISP GPU acceleration *: *YES" "$WORK/meson-setup.log" \
    || { grep -i "softisp" "$WORK/meson-setup.log"; echo "GPU debayer not enabled"; exit 1; }

echo "[3/5] Build ($(nproc) jobs)"
ninja -C build > "$WORK/ninja.log" 2>&1 || { tail -40 "$WORK/ninja.log"; exit 1; }

echo "[4/5] Stage (DESTDIR; meson signs the IPA)"
DESTDIR="$WORK/stage" meson install -C build > "$WORK/install.log" 2>&1 || { tail -20 "$WORK/install.log"; exit 1; }
S=$WORK/stage$PREFIX
ls "$S"/lib64/libcamera/ipa/ipa_soft_simple.so.sign >/dev/null   # signed -> in-process
T=$S/share/libcamera/ipa/simple
mkdir -p "$T"; rm -f "$T/ov5675.yaml"
ln -s /usr/share/libcamera/ipa/simple/ov5675.yaml "$T/ov5675.yaml"

echo "[5/5] Build info"
{
    echo "libcamera=$VR"
    echo "repo=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "built=$(date -Iseconds)"
    for p in $PATCHES; do echo "patch $p $(sha256sum < "$PDIR/$p.patch" | cut -c1-16)"; done
} > "$S/BUILD-INFO"
cat "$S/BUILD-INFO"
du -sh "$S" | cut -f1 | xargs echo "staged size:"
echo "Staged in $S. Try it as your user (relay idle):"
echo "  LD_LIBRARY_PATH=$S/lib64 GST_PLUGIN_PATH_1_0=$S/lib64/gstreamer-1.0 LIBCAMERA_IPA_MODULE_PATH=$S/lib64/libcamera/ipa ..."
echo "Install to $PREFIX: sudo bash $REPO/install-cam-tools.sh"
