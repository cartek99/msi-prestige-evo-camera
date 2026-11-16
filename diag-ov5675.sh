#!/usr/bin/env bash
# OV5675 probe diagnostic — run with sudo:  sudo bash ~/ipu7-cam-fix/diag-ov5675.sh
set +e

echo "===== [1] devices_deferred (is the sensor stuck waiting on a resource?) ====="
cat /sys/kernel/debug/devices_deferred 2>/dev/null || echo "(no deferred list / not accessible)"
echo

echo "===== [2] ov5675 / OVTI5675 probe log ====="
dmesg | grep -iE 'ov5675|OVTI5675' || echo "(no ov5675 lines in dmesg)"
echo

echo "===== [3] ipu bridge / csi2 / sensor wiring ====="
dmesg | grep -iE 'ipu_bridge|ipu-bridge|ipu7|csi2|sensor|swnode|fwnode' | tail -40
echo

echo "===== [4] regulator / gpio / clk / defer errors ====="
dmesg | grep -iE 'EPROBE_DEFER|deferred|regulator|gpio|clk|xvclk|clock-frequency' \
      | grep -iE 'ov5675|tps68470|int3472|defer|fail|error|not found'
echo

echo "===== [5] full int3472 / tps68470 boot sequence ====="
dmesg | grep -iE 'int3472|tps68470'
echo

echo "===== [6] sensor clock present in clk tree? ====="
grep -iE 'tps68470|ov5675|osc|xvclk|19200000|pmc_plt|clk_' /sys/kernel/debug/clk/clk_summary 2>/dev/null \
      || echo "(clk_summary not available)"
echo

echo "===== [7] is OVTI5675:00 bound to any driver? ====="
if [ -e /sys/bus/i2c/devices/i2c-OVTI5675:00/driver ]; then
  echo "BOUND -> $(readlink -f /sys/bus/i2c/devices/i2c-OVTI5675:00/driver)"
else
  echo "NOT bound to any driver"
fi
echo

echo "===== [8] modinfo ov5675 (confirm module present) ====="
modinfo ov5675 2>/dev/null | grep -E 'filename|vermagic' || echo "(ov5675 modinfo unavailable)"

echo
echo "===== DIAG DONE ====="
