# Register Decode (SVD)

Decode a peripheral register value using the CMSIS-SVD file for the current target.

## Locating the SVD file

1. Check `$SVD_FILE` environment variable.
2. Look in the workspace for `*.svd` files: `find /workspace -name "*.svd" -o -name "*.SVD" 2>/dev/null | head`
3. For the ARM leaf, CMSIS-DSP / CMSIS_6 do not ship SVDs — the user must supply theirs.

## Decoding a register value

Given a hex value (e.g. `0x00000223`) and a peripheral+register name (e.g. `RCC.CR`), find and decode:

```python
# Using cmsis-svd Python library (available as python-cmsis-svd if installed, otherwise parse manually)
import xml.etree.ElementTree as ET

def decode_register(svd_path, peripheral, register, value):
    tree = ET.parse(svd_path)
    root = tree.getroot()
    for periph in root.findall('.//peripheral'):
        if periph.findtext('name') == peripheral:
            for reg in periph.findall('.//register'):
                if reg.findtext('name') == register:
                    print(f"\n{peripheral}.{register} = 0x{value:08X}")
                    for field in reg.findall('.//field'):
                        name = field.findtext('name')
                        lsb = int(field.findtext('bitOffset') or field.findtext('lsb') or 0)
                        width = int(field.findtext('bitWidth') or
                                    (int(field.findtext('msb') or lsb) - lsb + 1))
                        mask = (1 << width) - 1
                        fval = (value >> lsb) & mask
                        desc = field.findtext('description', '').strip().split('\n')[0]
                        print(f"  [{lsb+width-1}:{lsb}] {name} = {fval:#x}  ({desc})")
```

Run it:
```bash
python3 -c "
import sys; sys.path.insert(0, '.')
# paste the function above, then:
decode_register('/workspace/STM32F405.svd', 'RCC', 'CR', 0x00000223)
"
```

## Alternative: gdb + svd-tools

If openocd or BMP is attached and a debug session is active:
```
(gdb) svd load /workspace/STM32F405.svd
(gdb) svd RCC CR
```

Cortex-Debug's Peripheral Viewer panel does this graphically — open it via the debug sidebar once a session is running.

## Manual bit-bashing

If no SVD is available, ask the user for the register's address and decode from the Reference Manual:
```bash
# Read from a running target via openocd telnet (port 4444)
echo "mdw 0x40023800" | nc localhost 4444
```
