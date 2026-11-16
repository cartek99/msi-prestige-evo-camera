#!/bin/bash
# cam-look.sh — switch the system-wide camera look (what Teams/Chrome/Zoom and the relay use).
#   bash cam-look.sh                show which look is installed
#   sudo bash cam-look.sh day       daylight-v1 (EV -0.5, neutral white balance) + denoise v64
#   sudo bash cam-look.sh night     clean-v1    (EV +0.75, warm; dim room with one lamp) + denoise v64x2
#   sudo bash cam-look.sh auto      auto-v1     (EV follows the light, -0.5..+0.75; needs IPA patch 0006) + v64x2i
#                                   day/night stay exactly as before: they are the rollback from auto.
#   sudo bash cam-look.sh NAME      any looks/NAME.yaml
# From Claude Code (no terminal for sudo):  ! pkexec bash ~/ipu7-cam-fix/cam-look.sh night
# Close camera apps first: the new look applies the next time an app opens the camera.
# Snapshot follows it too unless cam-tune live mode is on (bash cam-tune.sh off).
set -u
REPO=$(cd "$(dirname "$0")" && pwd)
DEST=/usr/share/libcamera/ipa/simple/ov5675.yaml
current() {
    for f in "$REPO"/looks/*.yaml; do
        cmp -s "$f" "$DEST" && { echo "installed look: $(basename "$f" .yaml)"; return; }
    done
    echo "installed look: none of looks/*.yaml (custom or older tuning)"
}
case "${1:-}" in
    "") current; exit 0 ;;
    day) NAME=daylight-v1; CHAIN=v64 ;;
    night) NAME=clean-v1; CHAIN=v64x2 ;;
    auto) NAME=auto-v1; CHAIN=v64x2i ;;
    *) NAME=$1; CHAIN= ;;
esac
SRC=$REPO/looks/$NAME.yaml
[ -f "$SRC" ] || { echo "no such look: $SRC"; ls "$REPO/looks"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run with sudo (or pkexec)"; exit 1; }
# auto-v1's keys need IPA patch 0006; on an older IPA the look would silently run at EV 0.
if [ "$NAME" = auto-v1 ] && ! strings /usr/lib64/libcamera/ipa/ipa_soft_simple.so 2>/dev/null | grep -q 'EV follows light'; then
    echo "the installed IPA lacks patch 0006 (EV follows light): first  sudo bash $REPO/apply-ipa-agc-patch.sh"; exit 1
fi
# Day and night also differ in denoise (M1: two passes airbrush daylight). Switch the relay
# chain too, unless it is raw or custom (diagnostics). The relay restart picks up the look.
NOW=$(bash "$REPO/cam-enhance.sh" | sed -n 's/^chain: *//p')
if [ -n "$CHAIN" ] && case "$NOW" in v64|v64x2|v64i|v64x2i) true ;; *) false ;; esac; then
    install -m 644 "$SRC" "$DEST"
    echo "installed look: $NAME"
    exec bash "$REPO/cam-enhance.sh" "$CHAIN"
fi
install -m 644 "$SRC" "$DEST"
echo "installed look: $NAME"
U=${SUDO_USER:-}
[ -z "$U" ] && [ -n "${PKEXEC_UID:-}" ] && U=$(id -nu "$PKEXEC_UID")   # pkexec (GUI password prompt) instead of sudo
if [ -n "$U" ] && [ "$U" != root ] && ! [ -f "/home/$U/.config/systemd/user/wireplumber.service.d/cam-tune.conf" ]; then
    uid=$(id -u "$U")
    sudo -u "$U" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user restart wireplumber \
        && echo "restarted WirePlumber so Snapshot picks it up (do this only with camera apps closed)"
fi
