#!/bin/bash
# STATUS: PARKED — PLAN M3 face-weighted exposure, built but off since 2026-11-11 (fixed windows cannot follow a face). See README.md.
# cam-ae.sh — face-weighted exposure for the relay via the private libcamera (PLAN M3).
#   cam-ae                       status
#   sudo cam-ae on [x,y,w,h,wt]  relay uses /opt/libcamera-ae with centre-weighted metering
#   sudo cam-ae off              relay back on the system libcamera (rollback)
# Window = fractions of the picture plus a weight (samples inside count wt times, outside once).
# The private GStreamer plugin has an rpath to /opt/libcamera-ae/lib64, so only GST_PLUGIN_PATH
# changes for the relay (no process-wide LD_LIBRARY_PATH). The look stays /usr/share's ov5675.yaml
# (cam-look day|night still works). Each switch clears the relay's GStreamer registry cache so a
# stale entry can't keep the other plugin. Close camera apps first: the relay restarts.
set -u
CONF=/etc/sysconfig/libcamera-loopback
OPT=/opt/libcamera-ae
DEFAULT_WIN="0.30,0.35,0.40,0.45,4"   # M3 sweep result; see docs/MILESTONES.md
REG=/var/cache/libcamera-loopback/gst-registry.bin
KEYS="GST_PLUGIN_PATH_1_0 LIBCAMERA_IPA_CONFIG_PATH LIBCAMERA_SOFTISP_AE_WINDOW LIBCAMERA_LOG_LEVELS"
LOG_OFF='*:WARN'
LOG_ON='*:WARN,SwStatsCpu:INFO,IPASoftExposure:INFO'   # journal shows the window + guard lines

val() { sed -n "s/^$1=//p" "$CONF" | tr -d "'"; }
run_log() {
    local id; id=$(systemctl show -p InvocationID --value libcamera-loopback)
    [ -n "$id" ] && journalctl -b --no-pager -o cat _SYSTEMD_INVOCATION_ID="$id" 2>/dev/null
}
built_for() { sed -n 's/^libcamera=//p' "$OPT/BUILD-INFO" 2>/dev/null; }
sys_vr() { rpm -q --qf '%{version}-%{release}' libcamera; }

status() {
    if [ -f "$OPT/BUILD-INFO" ]; then
        echo "private libcamera: $OPT (built for $(built_for), repo $(sed -n 's/^repo=//p' "$OPT/BUILD-INFO"))"
        [ "$(built_for)" = "$(sys_vr)" ] || echo "  MISMATCH: system libcamera is $(sys_vr): rebuild (build-libcamera-private.sh) or cam-ae off"
    else
        echo "private libcamera: not installed ($OPT)"
    fi
    if [ "$(val GST_PLUGIN_PATH_1_0)" = "$OPT/lib64/gstreamer-1.0" ]; then
        echo "relay:             face-weighted exposure ON, window $(val LIBCAMERA_SOFTISP_AE_WINDOW)"
    else
        echo "relay:             system libcamera (face-weighted exposure off)"
    fi
    local pid; pid=$(systemctl show -p MainPID --value libcamera-loopback)
    if [ -r "/proc/$pid/maps" ] && grep -q 'libcamera\.so' "/proc/$pid/maps" 2>/dev/null; then
        echo "streaming with:    $(grep -o '/[^ ]*libcamera\.so[^ ]*' "/proc/$pid/maps" | sort -u | head -1)"
    fi
}

case "${1:-}" in
    "") status; exit 0 ;;
    on) WIN=${2:-$DEFAULT_WIN}; [ "$WIN" = --force ] && WIN=$DEFAULT_WIN ;;
    off) ;;
    *) echo "usage: cam-ae [on [x,y,w,h,weight] | off]"; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
last=$(run_log | grep -o 'client usage: [0-9]*' | tail -1)
if [ -n "$last" ] && [ "${last##* }" != 0 ] && ! [[ " $* " == *" --force "* ]]; then
    echo "an app is reading the camera ($last): close it first, or add --force"; exit 1
fi
if [ "$1" = on ]; then
    [ -f "$OPT/BUILD-INFO" ] || { echo "$OPT missing: bash build-libcamera-private.sh, then sudo bash install-cam-tools.sh"; exit 1; }
    [ "$(built_for)" = "$(sys_vr)" ] || { echo "private build is for $(built_for), system is $(sys_vr): rebuild first"; exit 1; }
    [[ "$WIN" =~ ^[0-9.]+,[0-9.]+,[0-9.]+,[0-9.]+(,[0-9.]+)?$ ]] || { echo "bad window '$WIN' (x,y,w,h[,weight])"; exit 1; }
fi

[ -f "$CONF.pre-m3" ] || cp -p "$CONF" "$CONF.pre-m3"
tmp=$(mktemp)
grep -v -E "^($(echo $KEYS | tr ' ' '|'))=" "$CONF" > "$tmp"
if [ "$1" = on ]; then
    {
        echo "GST_PLUGIN_PATH_1_0=$OPT/lib64/gstreamer-1.0"
        echo "LIBCAMERA_IPA_CONFIG_PATH=/usr/share/libcamera/ipa"
        echo "LIBCAMERA_SOFTISP_AE_WINDOW=$WIN"
        echo "LIBCAMERA_LOG_LEVELS=$LOG_ON"
    } >> "$tmp"
else
    echo "LIBCAMERA_LOG_LEVELS=$LOG_OFF" >> "$tmp"
fi
install -m 644 "$tmp" "$CONF"; rm -f "$tmp"
rm -f "$REG"
systemctl restart libcamera-loopback
sleep 3
echo "relay: $(systemctl is-active libcamera-loopback)"
status
echo "The window is applied when an app opens the camera (journalctl -u libcamera-loopback shows it)."
