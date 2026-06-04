# Probe Troubleshoot

Diagnose "the probe won't flash / debug" issues. Walk through these steps in order and report what each command returns.

## Step 1: Is the probe visible on USB?

```bash
lsusb | grep -i -E "stlink|blackmagic|cmsis|wch|xds|jlink|picoprobe|ftdi|1d50|0483|1a86|0451|2e8a|1366"
```

**Nothing found:** the probe is not seen by the container.
- Check if `/dev/bus/usb` was mounted: `ls /dev/bus/usb`
- Check if you ran `dev-up.sh` AFTER plugging in the probe (bind-mount is read at container start).
- On the host: did the probe enumerate? `sudo dmesg | tail -20`
- Are host udev rules installed? `ls /etc/udev/rules.d/ | grep -E "blackmagic|stlink|wch"`

## Step 2: Can probe-rs see it?

```bash
probe-rs list
```

Expected output lists the probe with its USB VID:PID. If empty while `lsusb` shows the device, the issue is group/permissions — see Step 4.

## Step 3: Can st-info / stlink see it? (ST-Link only)

```bash
st-info --probe
```

## Step 4: Check group membership (most common issue)

```bash
id                          # shows current user's groups
ls -la /dev/bus/usb/*/*     # check group ownership of USB device nodes
```

The device node group (e.g. `plugdev` or `dialout`) must be in your `id` output. If not:
- Container was started without `--group-add plugdev` — restart with `dev-up.sh`.
- Host udev rule not installed — run `sudo ./scripts/install-host-udev-rules.sh` on the host, replug probe.

## Step 5: openocd scan

```bash
openocd -f interface/stlink.cfg -c "init; scan_chain; exit" 2>&1
# For BMP (acts as GDB server, no openocd needed — skip)
# For CMSIS-DAP:
openocd -f interface/cmsis-dap.cfg -c "init; scan_chain; exit" 2>&1
# For WCH-Link:
openocd -f interface/wlink-rs.cfg  -c "init; scan_chain; exit" 2>&1
```

**"Error: libusb_open() failed"** → permissions (Step 4).
**"Error: couldn't bind to port"** → another openocd or probe-rs is already using the probe; `pkill openocd; pkill probe-rs`.
**"JTAG scan chain interrogation failed"** → wrong target config, wrong SWD/JTAG mode, target not powered, wiring issue.

## Step 6: BMP-specific

```bash
ls /dev/ttyACM*          # BMP should show as two ACM devices
arm-none-eabi-gdb -ex "target extended-remote /dev/ttyACM0" \
                  -ex "monitor version" -ex "quit"
```

The `monitor version` response confirms BMP firmware version. Then `monitor swdp_scan` to scan for attached targets.

## Step 7: Target not responding

- Is the target powered? Measure VCC with a multimeter.
- Is SWD wired correctly? SWDIO, SWDCLK, GND — confirm with the probe pinout.
- Is there a BOOT0 / NRST condition forcing the target into DFU or a locked state? Try `monitor reset init` or hold NRST during connection.
- Is the flash locked (RDP level 1 or 2)? Only a chip erase can unlock (RDP1) or brick (RDP2).

## Summary output

Report for each step: the exact command output and whether the probe and target were successfully identified.
