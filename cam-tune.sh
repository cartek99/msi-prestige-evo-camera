#!/bin/bash
# cam-tune.sh — LIVE colour tuning of the built-in camera, watched in GNOME Snapshot.
#
# How it works: libcamera runs inside wireplumber (the PipeWire session manager)
# and reads the tuning file when it starts. "on" points wireplumber at a
# user-writable tuning dir (~/ipu7-cam-fix/live) via a systemd --user drop-in, so
# every change = rewrite live/simple/ov5675.yaml + restart wireplumber (~2 s,
# audio blips) + reopen Snapshot. No sudo while tuning.
#
#   bash cam-tune.sh            interactive one-key menu (turns live mode on)
#   bash cam-tune.sh on|off     enable / disable live mode (off = back to system tuning)
#   bash cam-tune.sh show       current values + final CCM
#   bash cam-tune.sh set KEY V  KEY = sat|warm|tint|bright|strength  (then reloads)
#   bash cam-tune.sh load FILE  use a solved CCM (9 numbers) as the base, strength=1
#   bash cam-tune.sh preset NAME / use NAME    save / restore the current params
#   bash cam-tune.sh match      voice cue -> grab -> compare with the phone photo
#   bash cam-tune.sh auto [N]   N measure/adjust rounds with voice cues (sit still when told)
#   bash cam-tune.sh reset      base = master ov5675.yaml CCM, all knobs neutral
#   bash cam-tune.sh commit "note"   write the result into master ov5675.yaml + git
#                                    (then: sudo bash apply-tuning.sh for Teams/Zoom)
#   add --no-snapshot (env NOSNAP=1) to skip reopening Snapshot.
set -e
REPO=$(cd "$(dirname "$0")" && pwd)
LIVE=$REPO/live
PARAMS=$LIVE/params.env
BASE=$LIVE/base-ccm.txt
YAML=$LIVE/simple/ov5675.yaml
HIST=$LIVE/history.log
DROPIN_DIR=$HOME/.config/systemd/user/wireplumber.service.d
DROPIN=$DROPIN_DIR/cam-tune.conf
PY="python3 $REPO/tools/cam_tune_ccm.py"
mkdir -p "$LIVE/simple" "$LIVE/presets"

seed_base() {   # base CCM = the ccm: [...] block of the master yaml
    python3 - "$REPO/ov5675.yaml" > "$BASE" <<'PY'
import re, sys
m = re.search(r"^ *ccm: \[([^\]]*)\]", open(sys.argv[1]).read(), re.M)
print(" ".join(m.group(1).replace(",", " ").split()))
PY
}
neutral_params() { printf 'SAT=1.00\nWARM=0.00\nTINT=0.00\nBRIGHT=1.00\nSTRENGTH=1.00\nEV=0.00\nGAMMA=2.20\nCONTRAST=1.00\n' > "$PARAMS"; }
IPADIR=$LIVE/ipa   # patched ipa_soft_simple.so for pre-install testing (optional)
[ -f "$BASE" ] || seed_base
[ -f "$PARAMS" ] || neutral_params

is_on() { [ -f "$DROPIN" ]; }
get() { grep "^$1=" "$PARAMS" | cut -d= -f2; }
put() { grep -q "^$1=" "$PARAMS" && sed -i "s/^$1=.*/$1=$2/" "$PARAMS" || echo "$1=$2" >> "$PARAMS"; }
for k in EV:0.00 GAMMA:2.20 CONTRAST:1.00; do grep -q "^${k%%:*}=" "$PARAMS" || echo "${k%%:*}=${k#*:}" >> "$PARAMS"; done
# Is a patched IPA (EV + Adjust defaults) what wireplumber will load?
patched_ipa() {
    [ -f "$IPADIR/ipa_soft_simple.so" ] && return 0
    strings /usr/lib64/libcamera/ipa/ipa_soft_simple.so 2>/dev/null | grep -q "Adjust defaults from tuning file"
}

reload() {
    $PY yaml "$PARAMS" "$BASE" "$YAML"
    echo "$(date '+%F %T') $(tr '\n' ' ' < "$PARAMS")" >> "$HIST"
    is_on || return 0
    local snap_was_open=0
    pgrep -x snapshot >/dev/null && snap_was_open=1
    pkill -x snapshot 2>/dev/null || true          # release the camera before reload
    systemctl --user restart wireplumber
    # wait for the camera node to come back (two back-to-back restarts wedged the IPA worker)
    for i in $(seq 1 20); do pw-cli ls Node 2>/dev/null | grep -q libcamera_input && break; sleep 0.5; done; sleep 1.5
    if [ -z "$NOSNAP" ] && { [ "$snap_was_open" = 1 ] || [ "$1" = open ]; }; then
        (setsid gtk-launch org.gnome.Snapshot >/dev/null 2>&1 &)
    fi
}

turn_on() {
    mkdir -p "$DROPIN_DIR"
    printf '[Service]\n# cam-tune.sh live mode — remove with: bash %s/cam-tune.sh off\nEnvironment=LIBCAMERA_IPA_CONFIG_PATH=%s\n' "$REPO" "$LIVE" > "$DROPIN"
    # pre-install test of the patched IPA: load it from live/ipa (unsigned -> isolated worker, fine)
    [ -f "$IPADIR/ipa_soft_simple.so" ] && printf 'Environment=LIBCAMERA_IPA_MODULE_PATH=%s\n' "$IPADIR" >> "$DROPIN"
    systemctl --user daemon-reload
    # Live tuning watches the native camera; M2 hides it behind the relay. Show it again
    # (reload restarts WirePlumber; one restart only, back-to-back ones wedged the IPA worker).
    bash "$REPO/cam-wp-rule.sh" native --no-restart
    reload open
    echo "Live mode ON — Snapshot now uses $YAML"
}
turn_off() {
    rm -f "$DROPIN"; systemctl --user daemon-reload
    pkill -x snapshot 2>/dev/null || true
    # Back to the enhanced-only camera if the relay runs an enhancement chain (cam-enhance.sh).
    case "$(bash "$REPO/cam-enhance.sh" | sed -n 's/^chain: *//p')" in
        v64*) bash "$REPO/cam-wp-rule.sh" enhanced --no-restart ;;   # v64 v64x2 v64i v64x2i
    esac
    systemctl --user restart wireplumber
    echo "Live mode OFF — Snapshot back on the system tuning (/usr/share/libcamera/ipa/simple/ov5675.yaml)"
}

show() {
    is_on && echo "LIVE MODE: ON  (Snapshot ≠ Teams until you commit + apply-tuning.sh, or run 'off')" \
          || echo "LIVE MODE: off"
    printf 'saturation %s | warmth %s | tint %s | brightness %s | strength %s\n' \
        "$(get SAT)" "$(get WARM)" "$(get TINT)" "$(get BRIGHT)" "$(get STRENGTH)"
    local note=""; patched_ipa || note="   <- NEED PATCHED IPA (no effect now)"
    printf 'exposure EV %s | gamma %s | contrast %s%s\n' "$(get EV)" "$(get GAMMA)" "$(get CONTRAST)" "$note"
    echo "final CCM:"; $PY ccm "$PARAMS" "$BASE" | sed 's/^/   /'
}

# ---- cues so Keith knows when to sit still ------------------------------------
SND=/usr/share/sounds/freedesktop/stereo
notify() { notify-send -a cam-tune -u critical "$1" "$2" 2>/dev/null || true; }
beep() { paplay "$SND/$1.oga" 2>/dev/null || true; }
say() { echo ">> $*"; spd-say -w -r -10 "$*" 2>/dev/null || espeak-ng "$*" 2>/dev/null || true; }
cue_and_grab() {   # cue_and_grab OUT.png
    notify "📷 cam-tune: sit still in 5 s" "Face centred, hands down, look at the camera"
    say "Get ready. Sit still and look at the camera, like your phone photo."
    for n in 3 2 1; do echo "   $n…"; beep audio-volume-change; sleep 1; done
    beep camera-shutter; echo "   capturing — hold still"
    bash "$REPO/cam-tune.sh" grab "$1"
    beep complete; say "Done. You can move."
}

step() {   # step KEY DELTA
    local v; v=$(python3 -c "print(f'{$(get "$1") + $2:.2f}')"); put "$1" "$v"
}

[ "$1" = "--no-snapshot" ] && { NOSNAP=1; shift; }
case "${1:-menu}" in
    on) turn_on ;;
    off) turn_off ;;
    show) show ;;
    set)
        case "$2" in sat) K=SAT;; warm) K=WARM;; tint) K=TINT;; bright) K=BRIGHT;; strength) K=STRENGTH;; ev) K=EV;; gamma) K=GAMMA;; contrast) K=CONTRAST;;
            *) echo "KEY = sat|warm|tint|bright|strength|ev|gamma|contrast"; exit 1;; esac
        put "$K" "$3"; reload; show ;;
    load)
        python3 - "$2" > "$BASE.new" <<'PY'
import re, sys
v = re.findall(r"-?\d+(?:\.\d+)?", open(sys.argv[1]).read().split("ccm:")[-1])
assert len(v) >= 9, "need 9 numbers"
print(" ".join(v[:9]))
PY
        cp "$BASE" "$LIVE/base-ccm.prev.txt"; mv "$BASE.new" "$BASE"; put STRENGTH 1.00
        reload; show ;;
    preset) cp "$PARAMS" "$LIVE/presets/$2.env"; cp "$BASE" "$LIVE/presets/$2.base"; echo "saved preset $2" ;;
    use) cp "$LIVE/presets/$2.env" "$PARAMS"; cp "$LIVE/presets/$2.base" "$BASE"; reload; show ;;
    reset) seed_base; neutral_params; reload; show ;;
    match)  # match [REF.jpg] — cue Keith, grab, compare with the phone reference photo
        REF=${2:?usage: cam-tune.sh match REFERENCE.jpg}
        cue_and_grab /tmp/cam-tune-match.png
        python3 "$REPO/tools/match-reference.py" "$REF" /tmp/cam-tune-match.png \
            --regions "${REF%.*}.regions.json" --params "$PARAMS" --write /tmp/cam-tune-suggest.env ;;
    auto)   # auto [ROUNDS] — measure -> apply (damped) suggestion -> reload, with voice cues
        R=${2:-3}; REF=${REF:?set REF=/path/to/reference.jpg}
        say "Starting $R tuning rounds. I will tell you each time to sit still."
        for i in $(seq 1 "$R"); do
            echo "=== round $i/$R ==="
            cue_and_grab /tmp/cam-tune-match.png
            cp /tmp/cam-tune-match.png "$LIVE/round-$(date +%H%M%S).png"
            python3 "$REPO/tools/match-reference.py" "$REF" /tmp/cam-tune-match.png \
                --regions "${REF%.*}.regions.json" --params "$PARAMS" \
                --write /tmp/cam-tune-suggest.env --damp 0.6 | grep -E "RMS|suggested:"
            [ "$i" = "$R" ] && break
            while IFS='=' read -r k v; do case "$k" in \#*|"") ;; *) put "$k" "$v";; esac; done < /tmp/cam-tune-suggest.env
            NOSNAP=1 reload
            sleep 2   # let AGC/AWB settle on the new settings
        done
        show
        say "Tuning rounds finished. Open Snapshot to have a look."
        notify "cam-tune finished" "Open Snapshot and check the look" ;;
    grab)   # grab OUT.png — tap the SAME PipeWire stream Snapshot shows (works while it's open)
        OUT=${2:-/tmp/cam-tune.png}; T=$(mktemp -d /tmp/ctg.XXXXXX)
        timeout 20 gst-launch-1.0 -q pipewiresrc target-object=libcamera_input.__SB_.LNK0 \
            ! videoconvert ! video/x-raw,format=RGB ! identity eos-after=60 ! pngenc \
            ! multifilesink location="$T/f-%03d.png" max-files=2 >/dev/null 2>&1 || true
        L=$(ls "$T"/f-*.png 2>/dev/null | sort | tail -1)
        [ -n "$L" ] || { echo "grab FAILED"; rm -rf "$T"; exit 1; }
        cp "$L" "$OUT"; rm -rf "$T"
        python3 - "$OUT" <<'PY'
import sys
from PIL import Image, ImageStat
im = Image.open(sys.argv[1]).convert("RGB"); w, h = im.size
f = ImageStat.Stat(im.crop((int(w*.42), int(h*.15), int(w*.56), int(h*.40)))).mean
a = ImageStat.Stat(im).mean
print(f"{sys.argv[1]}: frame lum {sum(a)/765:.2f} | face RGB {[round(x) for x in f]} "
      f"lum {sum(f)/765:.2f} chroma {max(f)-min(f):.0f}")
PY
        ;;
    commit)
        $PY commit "$PARAMS" "$BASE" "$REPO/ov5675.yaml" "${2:-live-tuned in Snapshot}"
        git -C "$REPO" add ov5675.yaml live/history.log 2>/dev/null || true
        git -C "$REPO" commit -q -m "ov5675.yaml: cam-tune commit — ${2:-live-tuned in Snapshot}" && echo "git committed."
        echo "Next, install system-wide (patched IPA + tuning, all apps):  sudo bash $REPO/apply-ipa-agc-patch.sh"
        echo "Then turn live mode off:        bash $REPO/cam-tune.sh off" ;;
    menu)
        is_on || turn_on
        while true; do
            clear 2>/dev/null || true
            echo "=== cam-tune — watch GNOME Snapshot (reopens ~3 s after each key) ==="
            show
            echo
            echo " s/S saturation -/+   w/W warmth -/+   t/T tint green/magenta"
            echo " b/B brightness -/+   x/X CCM strength -/+"
            echo " e/E exposure EV -/+  g/G gamma -/+   c/C contrast -/+   (patched IPA)"
            echo " m  measure vs phone reference (prints suggestions)"
            echo " p save preset   r reset   K commit to master   o live OFF + quit   q quit (stay live)"
            read -rsn1 k
            case "$k" in
                s) step SAT -0.05;; S) step SAT 0.05;;
                w) step WARM -0.02;; W) step WARM 0.02;;
                t) step TINT -0.02;; T) step TINT 0.02;;
                b) step BRIGHT -0.05;; B) step BRIGHT 0.05;;
                x) step STRENGTH -0.05;; X) step STRENGTH 0.05;;
                e) step EV -0.25;; E) step EV 0.25;;
                g) step GAMMA -0.1;; G) step GAMMA 0.1;;
                c) step CONTRAST -0.05;; C) step CONTRAST 0.05;;
                m) NOSNAP=1 bash "$REPO/cam-tune.sh" match; read -rsn1 -p "(any key)"; continue;;
                p) read -rp "preset name: " n; bash "$REPO/cam-tune.sh" preset "$n"; sleep 1; continue;;
                r) seed_base; neutral_params;;
                K) read -rp "note: " n; bash "$REPO/cam-tune.sh" commit "$n"; read -rsn1 -p "(any key)"; continue;;
                o) turn_off; exit 0;;
                q) exit 0;;
                *) continue;;
            esac
            reload open
        done ;;
    *) sed -n 2,22p "$REPO/cam-tune.sh" ;;
esac
