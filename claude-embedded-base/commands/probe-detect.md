Run diagnostic commands to identify all connected debug probes. Report what is found and flag any access issues.

Execute these commands and show all output:

```bash
echo "=== USB devices (probe-relevant) ==="
lsusb 2>/dev/null | grep -i -E "stlink|blackmagic|cmsis|wch|xds|jlink|picoprobe|1d50|0483|1a86|0451|2e8a|1366|0d28" || echo "(none matched)"

echo ""
echo "=== /dev/bus/usb available? ==="
ls /dev/bus/usb 2>/dev/null | head -5 || echo "NOT MOUNTED — restart container after plugging the probe"

echo ""
echo "=== Serial devices by-id ==="
ls /dev/serial/by-id/ 2>/dev/null || echo "(none)"

echo ""
echo "=== probe-rs list ==="
probe-rs list 2>/dev/null || echo "(probe-rs returned error)"

echo ""
echo "=== st-info --probe (ST-Link) ==="
st-info --probe 2>&1 || echo "(st-info returned error)"

echo ""
echo "=== Current user groups ==="
id

echo ""
echo "=== /dev/ttyACM* (BMP / ST-Link VCP) ==="
ls -la /dev/ttyACM* 2>/dev/null || echo "(none)"

echo ""
echo "=== openocd interface scan (first detected probe) ==="
timeout 5 openocd -f interface/stlink.cfg    -c "init; adapter list; exit" 2>&1 | head -10 || true
timeout 5 openocd -f interface/cmsis-dap.cfg -c "init; adapter list; exit" 2>&1 | head -10 || true
```

Based on the output, report:
1. Which probes are visible and working.
2. Any permission issues (missing group membership, missing udev rules).
3. Recommended next step to connect to the target (openocd command, BMP GDB attach command, or wlink command).
