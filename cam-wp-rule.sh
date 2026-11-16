#!/bin/bash
# cam-wp-rule.sh — which camera PipeWire apps (GNOME Snapshot) see. Run as your user, no sudo.
#   bash cam-wp-rule.sh             show the current rule
#   bash cam-wp-rule.sh enhanced    only the relay "Built-in Camera (Enhanced)"  (51-enhanced-only.conf)
#   bash cam-wp-rule.sh native      only the raw libcamera camera               (51-hide-relay-loopback.conf)
#   add --no-restart to only swap the file (the caller restarts WirePlumber itself)
# Called by cam-enhance.sh (v64/v64x2 -> enhanced, raw -> native) and cam-tune.sh (on -> native).
# Restarts WirePlumber when the rule changes (audio blips ~1 s): do it with camera apps closed,
# since restarting WirePlumber while the relay streams breaks Snapshot (PLAN finding 5).
set -u
HERE=$(dirname "$(readlink -f "$0")")
D=$HOME/.config/wireplumber/wireplumber.conf.d
EN=51-enhanced-only.conf
NA=51-hide-relay-loopback.conf

current() {
    local e=0 n=0
    cmp -s "$HERE/$EN" "$D/$EN" && e=1
    cmp -s "$HERE/$NA" "$D/$NA" && n=1
    case "$e$n" in
        10) echo enhanced ;;
        01) echo native ;;
        11) echo "both rules (no camera visible)" ;;
        *)  [ -e "$D/$EN" ] || [ -e "$D/$NA" ] && echo "custom (edited rule files)" \
                || echo "none (both cameras visible: Snapshot and the relay can fight over the sensor)" ;;
    esac
}

case "${1:-}" in
    "") current; exit 0 ;;
    enhanced) WANT=$EN; OTHER=$NA ;;
    native) WANT=$NA; OTHER=$EN ;;
    *) echo "usage: cam-wp-rule.sh [enhanced|native]"; exit 1 ;;
esac
[ "$(id -u)" -ne 0 ] || { echo "run as your user, not root"; exit 1; }
if [ "$(current)" = "$1" ]; then
    echo "wireplumber rule: $1 (unchanged)"; exit 0
fi
mkdir -p "$D"
rm -f "$D/$OTHER"
install -m 644 "$HERE/$WANT" "$D/$WANT"
if [ "${2:-}" = --no-restart ]; then echo "wireplumber rule: $1 (applies at the next WirePlumber restart)"
else systemctl --user restart wireplumber && echo "wireplumber rule: $1 (WirePlumber restarted)"; fi
