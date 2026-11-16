#!/bin/bash
# install-cam-tools.sh — root-owned copies of the camera switches, so sudo never runs a file
# that a program running as you could have edited (PLAN M2 red team #5).
#   sudo bash install-cam-tools.sh          install / update from this repo (re-run after edits)
#   sudo bash install-cam-tools.sh remove   uninstall
# Installs to /usr/local/lib/ipu7-cam/ (scripts, WirePlumber rules, looks/) plus commands
#   sudo cam-enhance [raw|v64|v64x2|selftest]     cam-enhance          (status)
#   sudo cam-look day|night                       cam-wp-rule enhanced|native   (as you)
#   sudo cam-ae on|off                            cam-ae               (status)
# Also installs the private libcamera (PLAN M3) from ~/.cache/ipu7-cam/lc-build/stage to
# /opt/libcamera-ae (root-owned) when a staged build exists and differs from the installed one.
# The repo scripts keep working as before; prefer the installed commands with sudo.
# check-cam-stack.sh [11] warns when the installed copy is older than the repo.
set -eu
REPO=$(cd "$(dirname "$0")" && pwd)
LIB=/usr/local/lib/ipu7-cam
BIN=/usr/local/bin
FILES="cam-enhance.sh cam-look.sh cam-wp-rule.sh cam-ae.sh 51-enhanced-only.conf 51-hide-relay-loopback.conf"
CMDS="cam-enhance cam-look cam-wp-rule cam-ae"
OPT=/opt/libcamera-ae
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

if [ "${1:-}" = remove ]; then
    for c in $CMDS; do rm -f "$BIN/$c"; done
    rm -rf "$LIB"
    echo "removed $LIB and the $CMDS commands"
    echo "(left $OPT in place: run 'sudo cam-ae off' first, then sudo rm -rf $OPT)"; exit 0
fi

install -d -m 755 -o root -g root "$LIB" "$LIB/looks" "$LIB/shaders"
for f in $FILES; do install -m 644 -o root -g root "$REPO/$f" "$LIB/$f"; done
install -m 644 -o root -g root "$REPO"/looks/*.yaml "$LIB/looks/"
install -m 644 -o root -g root "$REPO"/shaders/*.frag "$LIB/shaders/"   # cam-enhance v64i/v64x2i (M4a)
git -C "$REPO" rev-parse --short HEAD > "$LIB/VERSION" 2>/dev/null || date +%F > "$LIB/VERSION"
chmod 644 "$LIB/VERSION"
for c in $CMDS; do
    printf '#!/bin/bash\nexec /bin/bash %s/%s.sh "$@"\n' "$LIB" "$c" > "$BIN/$c"
    chown root:root "$BIN/$c"; chmod 755 "$BIN/$c"
done
echo "installed $(cat "$LIB/VERSION") to $LIB; commands: $(for c in $CMDS; do printf '%s ' "$BIN/$c"; done)"

# Private libcamera (M3): copy the staged build if it is new or changed.
U=${SUDO_USER:-}; [ -z "$U" ] && [ -n "${PKEXEC_UID:-}" ] && U=$(id -nu "$PKEXEC_UID")
STAGE=$( [ -n "$U" ] && getent passwd "$U" | cut -d: -f6 )/.cache/ipu7-cam/lc-build/stage$OPT
if [ -f "$STAGE/BUILD-INFO" ]; then
    if cmp -s "$STAGE/BUILD-INFO" "$OPT/BUILD-INFO"; then
        echo "private libcamera: $OPT up to date"
    else
        rm -rf "$OPT.new"; cp -a "$STAGE" "$OPT.new"
        chown -R root:root "$OPT.new"; chmod -R go-w "$OPT.new"
        rm -rf "$OPT.old"; [ -d "$OPT" ] && mv "$OPT" "$OPT.old"
        mv "$OPT.new" "$OPT"; rm -rf "$OPT.old"
        echo "private libcamera: installed $OPT ($(sed -n 's/^libcamera=//p' "$OPT/BUILD-INFO"), repo $(sed -n 's/^repo=//p' "$OPT/BUILD-INFO"))"
        echo "  (a running relay keeps the old files until it restarts: sudo cam-ae on|off restarts it)"
    fi
fi
if grep -rhs '^Defaults.*secure_path' /etc/sudoers /etc/sudoers.d/ | grep -q '/usr/local/bin'; then
    echo "sudo finds them (secure_path includes /usr/local/bin): sudo cam-enhance v64x2"
else
    echo "sudo's secure_path lacks /usr/local/bin: use  sudo $BIN/cam-enhance v64x2"
fi
