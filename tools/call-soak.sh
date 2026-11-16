#!/bin/bash
# call-soak.sh — log the camera relay and the laptop during a real call (PLAN M2 step 3). No sudo.
#   bash tools/call-soak.sh [MINUTES=30] [LABEL=call]
# Every 10 s: relay fps / late frames (from its --stats line), relay CPU % of one core (service
# cgroup), package temperature, average CPU clock, battery status / % / watts (on battery).
# Writes data/soak-LABEL-YYYYmmdd-HHMM.csv and prints a summary at the end (or on Ctrl-C).
# Start it, then join the call (screen share on for part of it, unplug the charger).
set -u
MIN=${1:-30}; LABEL=${2:-call}
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=$REPO/data/soak-$LABEL-$(date +%Y%m%d-%H%M).csv
CG=/sys/fs/cgroup$(systemctl show -p ControlGroup --value libcamera-loopback)
TZ_PKG=$(grep -l x86_pkg_temp /sys/class/thermal/thermal_zone*/type | head -1 | xargs dirname)
BAT=$(ls -d /sys/class/power_supply/BAT* | head -1)
usage() { awk '/usage_usec/{print $2}' "$CG/cpu.stat"; }
echo "time,fps,late_frames,max_gap_ms,relay_cpu_pct,pkg_temp_c,cpu_mhz_avg,bat_status,bat_pct,bat_watts,mode" > "$OUT"
echo "logging to $OUT for $MIN min (Ctrl-C ends early)"

summary() {
    echo; echo "=== summary ($OUT) ==="
    python3 -I - "$OUT" <<'PY'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1]))]
def col(k):
    out = []
    for r in rows:
        try: out.append(float(r[k]))
        except (ValueError, KeyError): pass
    return out
if not rows: print("no samples"); sys.exit()
fps, late, cpu, temp, mhz, w = (col(k) for k in ("fps", "late_frames", "relay_cpu_pct", "pkg_temp_c", "cpu_mhz_avg", "bat_watts"))
mn = lambda v: f"{min(v):.1f}" if v else "-"
mx = lambda v: f"{max(v):.1f}" if v else "-"
av = lambda v: f"{sum(v)/len(v):.1f}" if v else "-"
print(f"samples {len(rows)} ({len(rows)*10/60:.1f} min)")
print(f"relay fps      min {mn(fps)}  avg {av(fps)}   (target 29.5+)")
print(f"late frames    total {int(sum(late)) if late else '-'}  (arrivals > 50 ms)")
print(f"relay CPU %    avg {av(cpu)}  max {mx(cpu)}  (of one core; M1: 22)")
print(f"package temp   avg {av(temp)}  max {mx(temp)} C")
print(f"CPU clock      min {mn(mhz)}  avg {av(mhz)} MHz  (a falling clock at high temp = throttling)")
print(f"battery watts  avg {av(w)}  max {mx(w)}  (only while discharging)")
modes = sorted({r["mode"] for r in rows})
print("relay sources seen:", ", ".join(modes))
PY
}
trap 'summary; exit 0' INT TERM

END=$(( $(date +%s) + MIN * 60 ))
a=$(usage)
while [ "$(date +%s)" -lt "$END" ]; do
    sleep 10
    b=$(usage); cpu=$(awk -v a="$a" -v b="$b" 'BEGIN{printf "%.1f", (b-a)/100000}'); a=$b
    st=$(journalctl -u libcamera-loopback --since -11s --no-pager -o cat 2>/dev/null | grep 'stats ' | tail -1)
    fps=$(sed -n 's/.*= \([0-9.]*\) fps.*/\1/p' <<<"$st")
    late=$(sed -n 's/.*arrivals >[0-9]*ms: \([0-9]*\).*/\1/p' <<<"$st")
    gap=$(sed -n 's/.*(max \([0-9]*\) ms).*/\1/p' <<<"$st")
    temp=$(awk '{printf "%.1f", $1/1000}' "$TZ_PKG/temp")
    mhz=$(awk '/^cpu MHz/{s+=$4; n++} END{if(n) printf "%.0f", s/n}' /proc/cpuinfo)
    bs=$(cat "$BAT/status"); bp=$(cat "$BAT/capacity")
    w=""; [ "$bs" = Discharging ] && w=$(awk -v i="$(cat "$BAT/current_now")" -v v="$(cat "$BAT/voltage_now")" 'BEGIN{printf "%.1f", i*v/1e12}')
    last=$(journalctl -u libcamera-loopback --since -11s --no-pager -o cat 2>/dev/null | grep -E 'FALLBACK|stalled|giving up' | tail -1)
    mode=enhanced; [ -n "$last" ] && mode="EVENT: ${last#libcamera-loopback: }"; mode=${mode//,/;}
    [ -z "$fps" ] && { awk -v c="$cpu" 'BEGIN{exit !(c<2)}' && mode="idle (no reader)" || mode="starting (no stats line yet)"; }
    echo "$(date +%T),$fps,$late,$gap,$cpu,$temp,$mhz,$bs,$bp,$w,$mode" | tee -a "$OUT"
done
summary
