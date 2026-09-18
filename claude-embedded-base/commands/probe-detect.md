Run diagnostic commands to identify all connected debug probes. Report what is found and flag any access issues.

Execute these commands and show all output:

```bash
echo "=== dev-doctor (probe-relevant checks) ==="
dev-doctor 2>/dev/null | grep -E "usb-passthrough|probe-visible|groups|openocd|probe-rs|pyocd|st-info" || echo "(dev-doctor unavailable)"

echo ""
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
probe-rs list 2>&1 || echo "(probe-rs returned error)"

echo ""
echo "=== pyocd list ==="
pyocd list 2>&1 | head -10 || echo "(pyocd returned error)"

echo ""
echo "=== st-info --probe (ST-Link) ==="
st-info --probe 2>&1 || echo "(st-info returned error)"

echo ""
echo "=== Current user groups ==="
id

echo ""
echo "=== /dev/ttyACM* (BMP / ST-Link VCP) ==="
ls -la /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || echo "(none)"

echo ""
echo "=== openocd interface scan (first detected probe) ==="
timeout 5 openocd -f interface/stlink.cfg    -c "init; adapter list; exit" 2>&1 | head -10 || true
timeout 5 openocd -f interface/cmsis-dap.cfg -c "init; adapter list; exit" 2>&1 | head -10 || true

echo ""
echo "=== target declared by the workspace profile ==="
mcu --list 2>/dev/null || echo "(no .mcu-profile.json in $(pwd))"
```

Based on the output, report:

1. **Which probes are visible and working.**

2. **Any permission or passthrough problems.**
   - `/dev/bus/usb` missing → the container was started without `--device=/dev/bus/usb`, or the probe was plugged in *after* the container started. The bind mount is resolved at start, so replugging requires a container restart.
   - Probe visible in `lsusb` but tools cannot claim it → host udev rules are not installed. They ship at `/opt/embedded/udev-rules/` and must be installed **on the host** (`sudo /opt/embedded/install-host-udev-rules.sh` from a host checkout) — udev does not run inside a container, so the copy inside the image is inert.
   - Not in `dialout`/`plugdev` → `dev-up.sh` resolves the host GIDs and passes `--group-add`; if it did not, the host groups may not exist.

3. **Whether the workspace profile's `flashTool` matches what is actually connected.**

4. **The recommended next step**, as a concrete command:
   - openocd: `mcu debugServer`, or `openocd -f <interface> -f <target>`
   - probe-rs: `probe-rs list` then `probe-rs download --chip <chip> ...`
   - BMP: `arm-none-eabi-gdb -ex 'target extended-remote /dev/ttyACM0' -ex 'monitor swdp_scan'`
   - WCH-Link: `wlink info`

> **If the target is an STM32WBA6x (e.g. WBA65):** OpenOCD 0.12 does not support
> the part and will fail with `auto_probe failed` or a memory-read error even
> when the probe itself is fine. Confirm with `probe-rs list` and use
> `flashTool: "probe-rs"` in the profile — a probe that "does not work" on WBA65
> is usually a tool problem, not a wiring problem.
