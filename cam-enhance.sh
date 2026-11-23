#!/bin/bash
# cam-enhance.sh — the relay's enhancement chain (the camera every app sees). PLAN M2.
#   bash cam-enhance.sh                 status: look, chain, fallback, WirePlumber rule, label, live tuning
#   sudo bash cam-enhance.sh v64x2      GPU denoise, two passes (night; M1 winner, approved 2026-11-10)
#   sudo bash cam-enhance.sh v64        GPU denoise, one pass (day; keeps more detail)
#   sudo bash cam-enhance.sh v64x2i     v64x2 + GPU impulse filter (removes the per-frame speckle; PLAN M4a)
#   sudo bash cam-enhance.sh v64i       v64 + GPU impulse filter
#   bash cam-enhance.sh --print MODE    print a mode's LOOPBACK_SOURCE (no sudo; used by tools/gst-denoise-sweep.py)
#   sudo bash cam-enhance.sh raw        no enhancement; Snapshot gets the native camera (diagnostics/rollback)
#   sudo bash cam-enhance.sh selftest   break the chain on purpose, check the relay falls back, restore
# cam-look.sh day|night also sets v64|v64x2 (unless the chain is raw).
# Edits LOOPBACK_SOURCE (and adds LOOPBACK_FALLBACK_SOURCE if missing) in
# /etc/sysconfig/libcamera-loopback (first run keeps a backup next to it), then restarts
# libcamera-loopback. Close camera apps first: a restart cuts any live call video.
# Then sets your WirePlumber rule via cam-wp-rule.sh (enhanced for v64/v64x2, native for raw),
# except while cam-tune live mode is on (live tuning needs the native camera).
set -u
HERE=$(dirname "$(readlink -f "$0")")
CONF=/etc/sysconfig/libcamera-loopback
CAM='libcamerasrc camera-name=\\_SB_.LNK0'
# Pin the camera caps BEFORE the filters: the relay adds its own size caps only after
# LOOPBACK_SOURCE, and vapostproc can scale, so without this libcamera may pick another
# sensor mode. Don't end with caps: the relay appends its own video/x-raw caps right after
# LOOPBACK_SOURCE (two caps in a row = parse error), and those bring frames back to system memory.
CAPS='video/x-raw,width=1920,height=1080,framerate=30/1'
DN='vapostproc denoise=64'
# libcamerasrc delivers RGBA, and the VA denoise silently does nothing on RGBA (night clip: noise_t_y
# 5.36 -> 5.17 as RGBA vs 1.39 as NV12; live café ceiling 2.93 -> 2.92). Convert to NV12 on the GPU
# first, as the offline M1/M4 sweeps (NV12 input) assumed. Found 2026-11-23.
TONV12='vapostproc ! video/x-raw(memory:VAMemory),format=NV12'
SRC_RAW="$CAM"
SRC_V64="$CAM ! $CAPS ! $TONV12 ! $DN"
SRC_V64X2="$CAM ! $CAPS ! $TONV12 ! $DN ! $DN"
# M4a impulse filter: conditional 3x3 median in a GL shader (shaders/impulse3x3.frag), flattened
# to one line because glshader only takes inline source. The round trip goes back to NV12 on the
# GPU: leaving it RGBA drops the colorimetry and shifts colour (B/G -4% on the face, 2026-11-11).
IMP_THRESH=0.06
frag() { grep -v -E '^[[:space:]]*(//|$)' "$HERE/shaders/$1" | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/ $//'; }
IMPULSE="glupload ! glcolorconvert ! video/x-raw(memory:GLMemory),format=RGBA ! glshader fragment=\"$(frag impulse3x3.frag)\" uniforms=\"uniforms,thresh=(float)$IMP_THRESH\" ! glcolorconvert ! video/x-raw(memory:GLMemory),format=NV12 ! gldownload"
SRC_V64I="$SRC_V64 ! $IMPULSE"
SRC_V64X2I="$SRC_V64X2 ! $IMPULSE"

U=${SUDO_USER:-}
[ -z "$U" ] && [ -n "${PKEXEC_UID:-}" ] && U=$(id -nu "$PKEXEC_UID")
[ -z "$U" ] && [ "$(id -u)" -ne 0 ] && U=$(id -un)
UHOME=$( [ -n "$U" ] && getent passwd "$U" | cut -d: -f6 )
LIVE_DROPIN=$UHOME/.config/systemd/user/wireplumber.service.d/cam-tune.conf

src_now() { sed -n "s/^LOOPBACK_SOURCE='\(.*\)'$/\1/p" "$CONF"; }
mode_of() {
    case "$1" in
        "$SRC_RAW") echo raw ;; "$SRC_V64") echo v64 ;; "$SRC_V64X2") echo v64x2 ;;
        "$SRC_V64I") echo v64i ;; "$SRC_V64X2I") echo v64x2i ;;
        *) echo "custom: $1" ;;
    esac
}
# Lines the relay logged since it last started (this service run only).
run_log() {
    local id; id=$(systemctl show -p InvocationID --value libcamera-loopback)
    [ -n "$id" ] && journalctl -b --no-pager -o cat _SYSTEMD_INVOCATION_ID="$id" 2>/dev/null
}
as_user() {   # run a command as the desktop user (we may be root via sudo/pkexec)
    if [ "$(id -u)" -eq 0 ]; then
        local uid; uid=$(id -u "$U")
        runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$uid \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus "$@"
    else "$@"; fi
}
set_source() {   # set_source SRC: rewrite LOOPBACK_SOURCE, add the fallback if missing
    local tmp; tmp=$(mktemp)
    [ -f "$CONF.pre-m2" ] || cp -p "$CONF" "$CONF.pre-m2"
    grep -v -E '^LOOPBACK_SOURCE=' "$CONF" > "$tmp"
    grep -q '^LOOPBACK_FALLBACK_SOURCE=' "$tmp" || printf "LOOPBACK_FALLBACK_SOURCE='%s'\n" "$CAM" >> "$tmp"
    printf "LOOPBACK_SOURCE='%s'\n" "$1" >> "$tmp"
    install -m 644 "$tmp" "$CONF"; rm -f "$tmp"
}
camera_busy() {
    local last; last=$(run_log | grep -o 'client usage: [0-9]*' | tail -1)
    [ -n "$last" ] && [ "${last##* }" != "0" ] && { echo "$last"; return 0; }
    return 1
}

status() {
    echo "look:        $(bash "$HERE/cam-look.sh" | sed 's/^installed look: //')"
    echo "chain:       $(mode_of "$(src_now)")"
    grep -q '^LOOPBACK_FALLBACK_SOURCE=' "$CONF" && fb=set || fb="NOT SET (no fallback if the chain breaks)"
    # Since 0.1.0-6 the fallback lasts one stream: ACTIVE = the stream running now is on it.
    n=$(run_log | grep -c 'FALLBACK:')
    if [ "$n" -gt 0 ]; then
        fbsrc=$(sed -n "s/^LOOPBACK_FALLBACK_SOURCE='\(.*\)'$/\1/p" "$CONF")
        lastrun=$(run_log | grep -E '^libcamera-loopback: (starting|stopped)' | tail -1)
        case "$lastrun" in
            *"starting: $fbsrc !"*) fb="ACTIVE: the enhanced chain failed, this stream is on the plain camera" ;;
            *) fb="set (fell back $n time(s) since the relay started; last: $(run_log | grep 'pipeline error' | tail -1 | cut -c21-90))" ;;
        esac
    fi
    echo "fallback:    $fb"
    echo "relay:       $(systemctl is-active libcamera-loopback)"
    lbl=$(sed -n 's/^LOOPBACK_LABEL=//p' "$CONF")
    dev=$(cat /sys/devices/virtual/video4linux/*/name 2>/dev/null | head -1)
    case "|$lbl|" in *"|$dev|"*) m="matches" ;; *) m="MISMATCH: relay can't find the device" ;; esac
    echo "label:       device '$dev', relay looks for '$lbl' ($m)"
    if [ -n "$U" ] && [ "$U" != root ]; then
        echo "wireplumber: $(as_user bash "$HERE/cam-wp-rule.sh")"
        [ -f "$LIVE_DROPIN" ] && echo "live tuning: ON (cam-tune.sh; Snapshot shows the native camera)" \
            || echo "live tuning: off"
    fi
}

src_of() {
    case "$1" in
        raw) echo "$SRC_RAW" ;; v64) echo "$SRC_V64" ;; v64x2) echo "$SRC_V64X2" ;;
        v64i) echo "$SRC_V64I" ;; v64x2i) echo "$SRC_V64X2I" ;; *) return 1 ;;
    esac
}
USAGE="usage: cam-enhance.sh [raw|v64|v64x2|v64i|v64x2i|selftest|--print MODE]"
case "${1:-}" in
    "") status; exit 0 ;;
    --print) src_of "${2:-}" || { echo "$USAGE" >&2; exit 1; }; exit 0 ;;
    raw) SRC=$SRC_RAW; RULE=native ;;
    v64|v64x2|v64i|v64x2i) SRC=$(src_of "$1"); RULE=enhanced ;;
    selftest) ;;
    *) echo "$USAGE"; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
if busy=$(camera_busy) && [ "${2:-}" != --force ]; then
    echo "an app is reading the camera ($busy): close it first, or add --force"; exit 1
fi

if [ "$1" = selftest ]; then
    OLD=$(src_now)
    # Always put the real chain back, even on Ctrl-C or a closed terminal.
    restore() { set_source "$OLD"; systemctl restart libcamera-loopback; }
    trap 'restore; echo "interrupted: restored chain: $(mode_of "$(src_now)")"; exit 130' INT TERM HUP
    set_source "$CAM ! $CAPS ! vapostproc_selftest_missing"
    systemctl restart libcamera-loopback; sleep 2
    python3 -I /usr/libexec/libcamera-loopback/tools/frame-timing.py /dev/video0 60 2>&1 | grep -E '^frames' || true
    if run_log | grep -q 'FALLBACK:'; then r="PASS: broken chain -> relay fell back to the plain camera"
    else r="FAIL: no fallback logged (is libcamera-loopback >= 0.1.0-5 installed?)"; fi
    trap - INT TERM HUP
    restore; sleep 2
    echo "$r"; echo "restored chain: $(mode_of "$(src_now)")"
    case "$r" in PASS*) exit 0 ;; *) exit 1 ;; esac
fi

set_source "$SRC"
echo "chain: $(mode_of "$(src_now)")"
systemctl restart libcamera-loopback
sleep 3
echo "relay: $(systemctl is-active libcamera-loopback)"
run_log | grep -E 'format|ready|rror|FALLBACK' | tail -3

# WirePlumber rule, with the relay idle (restarting WirePlumber mid-stream breaks Snapshot).
if [ -z "$U" ] || [ "$U" = root ]; then
    echo "no SUDO_USER/PKEXEC_UID: run  bash $HERE/cam-wp-rule.sh $RULE  as your user"
elif [ -f "$LIVE_DROPIN" ] && [ "$RULE" = enhanced ]; then
    echo "wireplumber rule left native: cam-tune live mode is on (bash cam-tune.sh off to finish tuning)"
else
    as_user bash "$HERE/cam-wp-rule.sh" "$RULE"
fi
