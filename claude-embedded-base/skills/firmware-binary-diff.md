# Firmware Binary Diff

Compare two firmware builds and report function-level size changes, vector table differences, and `.rodata` deltas.

> Binutils calls below use `${CROSS_PREFIX}`, exported by each leaf image
> (`arm-none-eabi-` on the arm leaf, `riscv-none-elf-` on wch). It is empty in
> `embedded-base`, where the host binutils are used instead.

## Prerequisites

Two built `.elf` files to compare:
- `build_before/firmware.elf` (baseline)
- `build_after/firmware.elf` (modified)

## Step 1: Function-level size comparison

```bash
# Extract text symbols with sizes from both builds
${CROSS_PREFIX}nm -C --size-sort --print-size build_before/firmware.elf \
    | grep " [Tt] " | awk '{print $2, $4}' | sort -k2 > /tmp/before.txt
${CROSS_PREFIX}nm -C --size-sort --print-size build_after/firmware.elf \
    | grep " [Tt] " | awk '{print $2, $4}' | sort -k2 > /tmp/after.txt

# Show changed functions
diff /tmp/before.txt /tmp/after.txt | grep "^[<>]" \
    | awk '{sign=$1; size=strtonum("0x"$2); name=$3;
             if (sign==">") after[name]=size; else before[name]=size}
         END {for(n in after) {
             delta=after[n]-before[n];
             if (delta!=0) printf "%+5d  %s\n", delta, n
         }}' | sort -rn | head -30
```

## Step 2: Overall section size delta

```bash
echo "=== BEFORE ===" && ${CROSS_PREFIX}size build_before/firmware.elf
echo "=== AFTER ===" && ${CROSS_PREFIX}size build_after/firmware.elf
```

## Step 3: Vector table diff (ARM Cortex-M)

The vector table is at the start of `.text` at FLASH origin. A changed vector entry means a handler was added, removed, or renamed.

```bash
${CROSS_PREFIX}objdump -d build_before/firmware.elf | head -50 > /tmp/vtable_before.txt
${CROSS_PREFIX}objdump -d build_after/firmware.elf  | head -50 > /tmp/vtable_after.txt
diff /tmp/vtable_before.txt /tmp/vtable_after.txt
```

## Step 4: `.rodata` delta (strings, lookup tables)

```bash
${CROSS_PREFIX}objdump -s -j .rodata build_before/firmware.elf > /tmp/rodata_before.txt
${CROSS_PREFIX}objdump -s -j .rodata build_after/firmware.elf  > /tmp/rodata_after.txt
diff /tmp/rodata_before.txt /tmp/rodata_after.txt | head -40
```

## Step 5: New/removed symbols

```bash
comm -23 \
    <(${CROSS_PREFIX}nm -C build_before/firmware.elf | awk '{print $3}' | sort) \
    <(${CROSS_PREFIX}nm -C build_after/firmware.elf  | awk '{print $3}' | sort)
```

## Reporting

Present the results as:
1. Total size delta (`text`, `data`, `bss`).
2. Top 10 functions that grew, top 10 that shrank.
3. Any new or removed vector table entries.
4. Net assessment: does the change fit within the flash budget?
