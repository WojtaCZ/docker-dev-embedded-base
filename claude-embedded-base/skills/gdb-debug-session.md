# GDB Debug Session Recipes

Recipes for attaching GDB to a running embedded target via openocd or BMP.

## Via openocd (ST-Link / CMSIS-DAP / WCH-Link)

Start the openocd server first (VSCode "Debug" task, or manually):
```bash
openocd -f interface/stlink.cfg -f target/stm32f4x.cfg
# openocd listens on :3333 (GDB), :4444 (telnet), :6666 (TCL)
```

Attach from a second terminal:
```bash
arm-none-eabi-gdb build/firmware.elf \
    -ex "target extended-remote :3333" \
    -ex "monitor reset halt" \
    -ex "load" \
    -ex "monitor reset init" \
    -ex "break main" \
    -ex "continue"
```

## Via Black Magic Probe (BMP)

BMP acts as a native GDB server — no openocd needed.
```bash
# BMP enumerates as /dev/ttyACM0 (GDB) and /dev/ttyACM1 (target UART)
arm-none-eabi-gdb build/firmware.elf \
    -ex "target extended-remote /dev/ttyACM0" \
    -ex "monitor swdp_scan" \
    -ex "attach 1" \
    -ex "load" \
    -ex "break main" \
    -ex "run"
```

## Useful GDB commands

```
# Reset and halt the target
monitor reset halt

# Resume execution
continue   (or c)

# Step one source line (step into calls)
step   (or s)

# Step one source line (step over calls)
next   (or n)

# Print variable
print my_var
print/x my_var    # hex
print/t my_var    # binary

# Watch a memory-mapped register (e.g. GPIOA ODR = 0x40020014)
watch *((volatile uint32_t*)0x40020014)
awatch *((volatile uint32_t*)0x40020014)   # access watch (read+write)

# Display peripheral register via openocd telnet
(openocd telnet on port 4444)
mdw 0x40020014    # read 32-bit word from GPIOA_ODR
mww 0x40020018 0x00000020  # write BSRR to set PA5

# Dump 64 words from address
x/64xw 0x20000000

# Backtrace
bt
bt full    # with local variables
```

## Semihosting (printf to GDB console)

openocd:
```
monitor arm semihosting enable
```

BMP:
```
monitor semihosting enable
```

Add to startup code: `initialise_monitor_handles()` (from `<stdio.h>` in newlib with semihosting support). Linker flag: `-specs=rdimon.specs`.

## RTT (Segger Real-Time Transfer)

With probe-rs or openocd + RTT block in firmware:
```bash
probe-rs attach --chip STM32F405RGTx --protocol swd
# Then in the probe-rs REPL:
rtt
```

Or via openocd:
```
monitor rtt setup 0x20000000 0x10000 "SEGGER RTT"
monitor rtt start
monitor rtt server start 8765 0
```
Then `nc localhost 8765` to read channel 0.
