#!/bin/bash
# check-cam-stack.sh — post-kernel-update health check for the OV5675/IPU7 camera stack.
# Run after every kernel update (and any time the camera misbehaves):
#   bash ~/ipu7-cam-fix/check-cam-stack.sh
# Read-only. Exit code 0 = all good, 1 = action needed.
# History: created 2026-07-06, the day the camera first fully worked.

REPO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
KVER=$(uname -r)
FAIL=0
say()  { printf '%s\n' "$*"; }
ok()   { say "  ✅ $*"; }
bad()  { say "  ❌ $*"; FAIL=1; }
warn() { say "  ⚠️  $*"; }

say "=== Camera stack check — kernel $KVER ==="

# 2026-10-26: Fedora kernel 7.2.11 ships BOTH mainline fixes (621e4f762ed6 A2VMG board-data,
# d6576b85d3fe OVTI5675 in ipu-bridge). The 2 DKMS stopgaps are retired before the F44 upgrade.
# A DKMS package that is no longer registered at all counts as RETIRED (healthy if stock has the fix).
retired() { [ -z "$(dkms status "$1" 2>/dev/null)" ]; }
STOCK_BRIDGE="/lib/modules/$KVER/kernel/drivers/media/pci/intel/ipu-bridge.ko.xz"
STOCK_INT3472="/lib/modules/$KVER/kernel/drivers/platform/x86/intel/int3472/intel_skl_int3472_tps68470.ko.xz"
if retired ipu-bridge-ov5675 && retired intel-skl-int3472-tps68470-msi-a2vmg; then
    DKMS_RETIRED=1
    say "(DKMS stopgaps retired — checking that the STOCK kernel modules carry both fixes)"
fi

say "[1] kernel-devel present for running kernel (DKMS can't build without it)"
if [ -n "$DKMS_RETIRED" ]; then
    ok "not needed — no camera DKMS modules (akmod-v4l2loopback pulls its own kernel-devel)"
elif rpm -q "kernel-devel-$KVER" &>/dev/null || [ -d "/usr/src/kernels/$KVER" ]; then
    ok "kernel-devel for $KVER present"
else
    bad "kernel-devel for $KVER MISSING → sudo dnf install kernel-devel-$KVER, then: sudo dkms autoinstall"
fi

say "[2] DKMS modules built+installed for running kernel"
for mod in intel-skl-int3472-tps68470-msi-a2vmg/1.0 ipu-bridge-ov5675/1.0; do
    if retired "${mod%/*}"; then
        ok "$mod retired (stock kernel carries the fix — verified in [4]/[5b])"
    elif dkms status "$mod" 2>/dev/null | grep -q "$KVER.*installed"; then
        ok "$mod installed for $KVER"
    else
        bad "$mod NOT installed for $KVER → sudo dkms autoinstall (check build log under /var/lib/dkms)"
    fi
done

say "[3] Which ipu-bridge does modprobe resolve? (must be /extra = DKMS, until Fedora ships OVTI5675)"
BRIDGE=$(modinfo -n ipu_bridge 2>/dev/null)
case "$BRIDGE" in
    */extra/*)  ok "DKMS module active: $BRIDGE" ;;
    "")         bad "ipu_bridge module not found at all" ;;
    "$STOCK_BRIDGE") if xz -dcf "$BRIDGE" | strings | grep -q OVTI5675; then ok "STOCK module resolves and has OVTI5675: $BRIDGE"; else bad "STOCK $BRIDGE lacks OVTI5675 → reinstall DKMS #2: sudo dkms install ipu-bridge-ov5675/1.0"; fi ;;
    *)          warn "STOCK module resolves: $BRIDGE — check [4] below" ;;
esac

say "[4] Does the STOCK kernel ipu-bridge now include OVTI5675? (Fedora catching up = retire DKMS #2)"
# DKMS archives the stock module when it installs its own; check both locations.
STOCK="/lib/modules/$KVER/kernel/drivers/media/pci/intel/ipu-bridge.ko.xz"
[ -f "$STOCK" ] || STOCK=$(ls /var/lib/dkms/ipu-bridge-ov5675/original_module/"$KVER"/*/ipu-bridge.ko* 2>/dev/null | head -1)
if [ -n "$STOCK" ] && [ -f "$STOCK" ]; then
    if xz -dcf "$STOCK" 2>/dev/null | strings | grep -q OVTI5675; then
        if retired ipu-bridge-ov5675; then
            ok "Stock kernel has OVTI5675 and DKMS #2 is retired"
        else
            warn "Stock kernel NOW HAS OVTI5675 → DKMS #2 is redundant. Retire it:"
            warn "    sudo dkms remove -m ipu-bridge-ov5675 -v 1.0 --all && sudo depmod -a && sudo reboot"
        fi
    else
        if retired ipu-bridge-ov5675; then
            bad "Stock kernel LACKS OVTI5675 but DKMS #2 is retired → sudo dkms install ipu-bridge-ov5675/1.0 && sudo reboot"
        else
            ok "Stock kernel still lacks OVTI5675 — DKMS #2 still needed ($STOCK)"
        fi
    fi
else
    warn "Stock ipu-bridge not found in kernel path or DKMS archive — nothing to compare"
fi

say "[5] Board-data (FIX #1) active? (A2VMG strings in resolved int3472 module)"
T=$(modinfo -n intel_skl_int3472_tps68470 2>/dev/null)
if [ -n "$T" ] && xz -dcf "$T" 2>/dev/null | strings | grep -q A2VMG; then
    ok "A2VMG board-data present in $T"
else
    bad "A2VMG board-data NOT in resolved module ($T) — FIX #1 inactive → camera has no power"
fi

say "[5b] Does the STOCK kernel int3472 now include A2VMG? (upstream 621e4f762ed6, merged 2026-03-19 → retire DKMS #1)"
STOCK1="/lib/modules/$KVER/kernel/drivers/platform/x86/intel/int3472/intel_skl_int3472_tps68470.ko.xz"
[ -f "$STOCK1" ] || STOCK1=$(ls /var/lib/dkms/intel-skl-int3472-tps68470-msi-a2vmg/original_module/"$KVER"/*/intel_skl_int3472_tps68470.ko* 2>/dev/null | head -1)
if [ -n "$STOCK1" ] && [ -f "$STOCK1" ]; then
    if xz -dcf "$STOCK1" 2>/dev/null | strings | grep -q A2VMG; then
        if retired intel-skl-int3472-tps68470-msi-a2vmg; then
            ok "Stock kernel has A2VMG board-data and DKMS #1 is retired"
        else
            warn "Stock kernel NOW HAS A2VMG board-data → DKMS #1 is redundant. Retire it:"
            warn "    sudo dkms remove -m intel-skl-int3472-tps68470-msi-a2vmg -v 1.0 --all && sudo depmod -a && sudo reboot"
        fi
    else
        if retired intel-skl-int3472-tps68470-msi-a2vmg; then
            bad "Stock kernel LACKS A2VMG but DKMS #1 is retired → sudo dkms install intel-skl-int3472-tps68470-msi-a2vmg/1.0 && sudo reboot"
        else
            ok "Stock kernel still lacks A2VMG — DKMS #1 still needed ($STOCK1)"
        fi
    fi
else
    warn "Stock int3472 tps68470 module not found in kernel path or DKMS archive — nothing to compare"
fi

say "[6] Live state: sensor bound + media graph"
if [ -e /sys/bus/i2c/devices/i2c-OVTI5675:00/driver ]; then
    ok "i2c-OVTI5675:00 bound to $(basename "$(readlink /sys/bus/i2c/devices/i2c-OVTI5675:00/driver)")"
else
    bad "i2c-OVTI5675:00 not bound to any driver"
fi
# Scan every /dev/media* — a USB webcam (Logitech) can take media0 and push IPU7 to media1.
MDEV=""
for m in /dev/media*; do media-ctl -p -d "$m" 2>/dev/null | grep -q 'ov5675' && { MDEV=$m; break; }; done
if command -v media-ctl &>/dev/null && [ -n "$MDEV" ]; then
    ok "ov5675 entity present in media graph ($MDEV)"
else
    bad "ov5675 entity NOT in media graph"
fi

say "[7] Userspace sees the camera (PipeWire first — that's what apps use; cam -l fights over the device)"
if command -v wpctl &>/dev/null && wpctl status 2>/dev/null | grep -q 'Built-in Front Camera'; then
    ok "PipeWire source 'Built-in Front Camera' present"
elif command -v wpctl &>/dev/null && wpctl status 2>/dev/null | grep -q 'Built-in Camera (Enhanced)\|Intel MIPI Camera (V4L2)' \
     && [ "$(bash $REPO/cam-wp-rule.sh 2>/dev/null)" = enhanced ]; then
    ok "PipeWire source is the relay (M2 enhanced-only: raw camera hidden on purpose)"
elif command -v cam &>/dev/null && cam -l 2>/dev/null | grep -q 'LNK0'; then
    ok "cam -l lists the internal camera (PipeWire source absent — check wireplumber)"
elif command -v cam &>/dev/null && cam -l 2>&1 | grep -q 'resource busy'; then
    warn "Camera device BUSY (another app/PipeWire holds it) — likely fine; close apps and re-run to be sure"
else
    bad "Neither PipeWire nor cam -l sees the camera"
fi

say "[7b] OV5675 color tuning file installed? (lost = washed-out green image returns)"
if grep -qE '^\s*- Lut:' /usr/share/libcamera/ipa/simple/ov5675.yaml 2>/dev/null && \
   [ "$(rpm -q --qf '%{version}' libcamera | cut -d. -f2)" -ge 7 ]; then
    bad "ov5675.yaml uses 'Lut' (renamed 'Adjust' in libcamera 0.7) → soft ISP fails to init → sudo cam-look auto"
elif [ -f /usr/share/libcamera/ipa/simple/ov5675.yaml ]; then
    ok "ov5675.yaml tuning present"
else
    bad "ov5675.yaml MISSING (libcamera update?) → sudo cam-look auto"
fi

say "[8a] v4l2loopback module (a missing module makes libcamera-loopback skip starting, silently)"
if [ -d /sys/module/v4l2loopback ]; then
    LBVER=$(modinfo -F version v4l2loopback 2>/dev/null)
    LBBUF=$(cat /sys/module/v4l2loopback/parameters/max_buffers 2>/dev/null)
    if [ "$(printf '%s\n0.13\n' "$LBVER" | sort -V | head -1)" = "0.13" ]; then
        ok "v4l2loopback $LBVER loaded (>= 0.13 reports reader start/stop), max_buffers=$LBBUF"
    else
        bad "v4l2loopback $LBVER < 0.13 → on-demand start won't work → sudo dnf install akmod-v4l2loopback"
    fi
    rpm -q akmod-v4l2loopback &>/dev/null || warn "no akmod-v4l2loopback → a kernel update may leave no module"
else
    bad "v4l2loopback NOT loaded → sudo modprobe v4l2loopback (akmod built for $KVER?)"
fi
LBLABEL=$(cat /sys/devices/virtual/video4linux/video*/name 2>/dev/null | head -1)
[ "$LBLABEL" = "Intel MIPI Camera" ] || [ "$LBLABEL" = "Built-in Camera (Enhanced)" ] \
    && ok "loopback label: $LBLABEL" || warn "unexpected loopback label: '$LBLABEL'"

say "[8b] Exactly one relay enabled (both enabled = race at boot)"
NEW_ON=0; OLD_ON=0
systemctl is-enabled --quiet libcamera-loopback 2>/dev/null && NEW_ON=1
# v4l2-relayd's generator links every /etc/v4l2-relayd.d/*.conf instance under the
# stub v4l2-relayd.service at each boot (shows as "enabled-runtime"). Those only
# start if the stub is enabled, so count them only then.
for u in v4l2-relayd@libcamerasrc v4l2-relayd@default; do
    case "$(systemctl is-enabled "$u" 2>/dev/null)" in
        enabled) OLD_ON=1 ;;
        enabled-runtime) systemctl is-enabled --quiet v4l2-relayd.service 2>/dev/null && OLD_ON=1 ;;
    esac
done
if [ $((NEW_ON + OLD_ON)) -eq 2 ]; then
    bad "libcamera-loopback AND v4l2-relayd both enabled (the v4l2-relayd generator re-creates instances at boot) → sudo systemctl disable v4l2-relayd.service; sudo systemctl stop v4l2-relayd@libcamerasrc"
elif [ $((NEW_ON + OLD_ON)) -eq 0 ]; then
    warn "no relay enabled (fine during the step-R hand run; otherwise Teams/Chrome has no camera)"
fi

if [ "$NEW_ON" -eq 1 ]; then
    say "[8] Teams/Chrome path: libcamera-loopback feeding '$LBLABEL'"
    systemctl is-active --quiet libcamera-loopback \
        && ok "libcamera-loopback active (camera starts only while an app reads)" \
        || bad "libcamera-loopback NOT active → journalctl -u libcamera-loopback -b; sudo systemctl restart libcamera-loopback"
    [ "$LBBUF" = "3" ] || bad "max_buffers=$LBBUF, libcamera-loopback needs 3 → reboot (package sets it) or sudo /usr/libexec/libcamera-loopback/set-loopback-buffers.sh 3"
else
    say "[8] Teams/Chrome path (old relay): v4l2-relayd feeding 'Intel MIPI Camera' loopback"
    if systemctl is-active v4l2-relayd@libcamerasrc &>/dev/null; then
        ok "v4l2-relayd@libcamerasrc active"
        # Only inspect the CURRENT service invocation (whole-boot grep would see pre-fix errors)
        INVOC=$(systemctl show -p InvocationID --value v4l2-relayd@libcamerasrc 2>/dev/null)
        if [ -n "$INVOC" ] && journalctl "_SYSTEMD_INVOCATION_ID=$INVOC" --no-pager 2>/dev/null | grep -q 'Could not open any dma-buf provider'; then
            bad "SoftISP dma-buf error in relay log → check the relay unit allows /dev/udmabuf and /dev/dma_heap"
        fi
    else
        bad "v4l2-relayd@libcamerasrc NOT active → Teams/Chrome camera dead → sudo systemctl restart v4l2-relayd@libcamerasrc"
    fi
fi

say "[9] Patched soft-ISP IPA (AGC ExposureValue + AWB manual WB) installed?"
IPASO=/usr/lib64/libcamera/ipa/ipa_soft_simple.so
if [ -f "$IPASO" ] && strings "$IPASO" 2>/dev/null | grep -q 'Fixed white-balance gains from tuning file'; then
    ok "patched ipa_soft_simple.so present (honors exposureValue + fixed WB gains)"
elif [ -f "$IPASO" ] && strings "$IPASO" 2>/dev/null | grep -q 'Default exposure value from tuning file'; then
    warn "AGC-only patched IPA (no AWB patch) — re-run apply-ipa-agc-patch.sh to get the WB fix"
elif [ "$(cat $REPO/prebuilt/BUILT_FOR 2>/dev/null)" != "$(rpm -q --qf '%{version}-%{release}' libcamera)" ]; then
    # Never point at apply-ipa-agc-patch.sh here: a prebuilt for another libcamera breaks the camera.
    warn "STOCK IPA on libcamera $(rpm -q --qf '%{version}-%{release}' libcamera) — prebuilt is for $(cat $REPO/prebuilt/BUILT_FOR 2>/dev/null)."
    warn "    Camera works, but auto-WB (cool cast) + no EV bias. Rebuild: bash $REPO/build-ipa-patch.sh, then sudo bash $REPO/apply-ipa-agc-patch.sh"
elif grep -qE '^\s*(exposureValue|gains):' /usr/share/libcamera/ipa/simple/ov5675.yaml 2>/dev/null; then
    bad "STOCK IPA restored (libcamera update?) — tuning needs the patched IPA → cyan cast + clipping return → sudo bash $REPO/apply-ipa-agc-patch.sh"
else
    warn "stock IPA and no patched tuning — exposure/WB fixes not applied"
fi
if [ -f "$IPASO" ] && ! strings "$IPASO" 2>/dev/null | grep -q 'Adjust defaults from tuning file' \
   && grep -qE '^\s*(gamma|contrast):' /usr/share/libcamera/ipa/simple/ov5675.yaml 2>/dev/null; then
    bad "tuning sets gamma/contrast but the IPA lacks patch 0003 (Adjust defaults) → rebuild + apply-ipa-agc-patch.sh"
fi
# M4b: patch 0006 "EV follows light" (auto-v1 look). Without it the ramp keys are ignored → EV 0.
if grep -qE '^\s*lightBright:' /usr/share/libcamera/ipa/simple/ov5675.yaml 2>/dev/null; then
    if strings "$IPASO" 2>/dev/null | grep -q 'EV follows light'; then
        ok "EV follows light: IPA patch 0006 + ramp keys in the tuning (look auto)"
    else
        bad "tuning has EV-follows-light keys but the IPA lacks patch 0006 → EV stuck at 0 → sudo bash $REPO/apply-ipa-agc-patch.sh (or sudo cam-look night)"
    fi
elif strings "$IPASO" 2>/dev/null | grep -q 'EV follows light'; then
    ok "IPA has patch 0006 (EV follows light; idle with this look: fixed exposureValue)"
fi
# [9b] cam-tune live mode left on → Snapshot uses $REPO/live, Teams uses the system tuning
if [ -f "$HOME/.config/systemd/user/wireplumber.service.d/cam-tune.conf" ]; then
    warn "[9b] cam-tune LIVE MODE is ON — Snapshot and Teams use different tuning. Finish with: bash $REPO/cam-tune.sh off"
fi

say "[10] libcamera version-locked + installed tuning matches repo master"
if dnf versionlock list 2>/dev/null | grep -qE '^(libcamera-0|Package name: libcamera$)'; then
    ok "libcamera version-locked ($(rpm -q --qf '%{version}-%{release}' libcamera))"
else
    warn "libcamera NOT version-locked → an update can silently replace the patched IPA → sudo dnf versionlock add libcamera libcamera-ipa libcamera-gstreamer"
fi
LOOK=$(bash $REPO/cam-look.sh 2>/dev/null)
if [[ "$LOOK" != *"none of"* ]]; then
    ok "$LOOK (switch: sudo cam-look day|night|auto)"
else
    warn "installed ov5675.yaml matches no saved look in looks/ (relay runs as root and uses it) → sudo bash $REPO/cam-look.sh day|night"
fi

say "[11] Enhanced camera (M2): chain, fallback, label, WirePlumber rule"
ST=$(bash $REPO/cam-enhance.sh 2>/dev/null)
field() { printf '%s\n' "$ST" | sed -n "s/^$1: *//p"; }
CH=$(field chain); FB=$(field fallback); LB=$(field label); WR=$(field wireplumber)
case "$CH" in
    v64|v64x2|v64i|v64x2i|raw) ok "chain: $CH (look: $(field look))" ;;
    # v64i/v64x2i embed shaders/impulse3x3.frag: after editing the shader, re-run sudo cam-enhance <mode>
    custom*glshader*) warn "chain: custom GL chain (shader edited since it was set?) → sudo cam-enhance v64x2i" ;;
    *) warn "chain: $CH" ;;
esac
case "$FB" in
    set) ok "fallback source set (a broken GPU filter degrades to the plain camera)" ;;
    "set (fell back"*) warn "fallback: ${FB#set } → journalctl -u libcamera-loopback | grep -B3 FALLBACK (GPU driver update? resume?)" ;;
    ACTIVE*) bad "relay is on the FALLBACK source now: the enhancement chain failed → journalctl -u libcamera-loopback | grep -B3 FALLBACK; reopening the camera retries it" ;;
    *) warn "fallback: $FB → install libcamera-loopback >= 0.1.0-5" ;;
esac
case "$LB" in *MISMATCH*) bad "label: $LB" ;; *) ok "label: $LB" ;; esac
case "$CH:$WR" in
    v64:enhanced|v64x2:enhanced|v64i:enhanced|v64x2i:enhanced|raw:native) ok "wireplumber rule: $WR (matches chain $CH)" ;;
    *:native) [ "$(field 'live tuning')" != off ] && ok "wireplumber rule: native (cam-tune live mode)" \
                  || warn "wireplumber rule native but chain $CH → bash $REPO/cam-wp-rule.sh enhanced" ;;
    *) warn "wireplumber rule: $WR (chain $CH) → bash $REPO/cam-wp-rule.sh enhanced|native" ;;
esac
LIBV=/usr/local/lib/ipu7-cam/VERSION
if [ -f "$LIBV" ]; then
    stale=""
    for f in cam-enhance.sh cam-look.sh cam-wp-rule.sh 51-enhanced-only.conf 51-hide-relay-loopback.conf shaders/impulse3x3.frag; do
        cmp -s $REPO/$f /usr/local/lib/ipu7-cam/$f || stale="$stale $f"
    done
    [ -z "$stale" ] && ok "root-owned tools installed ($(cat "$LIBV")), same as repo" \
        || warn "installed tools differ from repo:$stale → sudo bash $REPO/install-cam-tools.sh"
else
    warn "root-owned tools not installed (sudo runs repo files you can edit) → sudo bash $REPO/install-cam-tools.sh"
fi
if [ "$WR" = enhanced ] && wpctl status 2>/dev/null | grep -q 'Built-in Front Camera'; then
    bad "raw camera visible despite the enhanced-only rule (node renamed?) → Snapshot and the relay fight over the sensor; check: pw-cli ls Node | grep libcamera_input"
fi

say "[12] Face-weighted exposure (M3): private libcamera"
AE=$(bash $REPO/cam-ae.sh 2>/dev/null)
OPTI=/opt/libcamera-ae/BUILD-INFO
if printf '%s' "$AE" | grep -q "face-weighted exposure ON"; then
    if [ ! -f "$OPTI" ]; then
        bad "relay set to /opt/libcamera-ae but it is missing → sudo cam-ae off (camera is down otherwise)"
    elif printf '%s' "$AE" | grep -q MISMATCH; then
        bad "$(printf '%s' "$AE" | grep MISMATCH | sed 's/^ *//') → no camera risk; sudo cam-ae off"
    else
        ok "$(printf '%s' "$AE" | grep '^relay:' | sed 's/^relay: *//')"
        grep -qE '^\s*lightBright:' /usr/share/libcamera/ipa/simple/ov5675.yaml 2>/dev/null && \
            warn "look auto needs IPA patch 0006, which the private M3 build lacks → EV fixed at 0 → sudo cam-ae off"
        ok "$(printf '%s' "$AE" | grep '^private' | sed 's/^private libcamera: *//')"
    fi
    # same IPA patch set as the system prebuilt (0001-0003) and as the repo (all)
    while read -r _ name hash; do
        f=$REPO/patches/libcamera-0.7/$name.patch
        [ -f "$f" ] && [ "$(sha256sum < "$f" | cut -c1-16)" != "$hash" ] && \
            warn "private build has an older $name than the repo → bash build-libcamera-private.sh && sudo bash install-cam-tools.sh"
    done < <(grep '^patch ' "$OPTI" 2>/dev/null)
    printf '%s' "$AE" | grep -q '^streaming with:.*/opt/libcamera-ae' && ok "relay is streaming with the private libcamera"
    printf '%s' "$AE" | grep -q '^streaming with:.*/usr/lib' && bad "relay is set to the private libcamera but streams with the system one (stale GStreamer registry?) → sudo cam-ae on"
else
    ok "relay on the system libcamera (face-weighted exposure off)"
    [ -f "$OPTI" ] && say "     private build present: sudo cam-ae on to use it"
fi

say ""
if [ "$FAIL" -eq 0 ]; then
    say "=== ALL GOOD — camera stack healthy on $KVER ==="
else
    say "=== ACTION NEEDED — see ❌ items above. Deep dive: sudo bash $REPO/diag-ov5675.sh ==="
fi
exit $FAIL
