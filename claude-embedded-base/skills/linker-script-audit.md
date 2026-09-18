# Linker Script Audit

Audit the linker script(s) in the workspace against the target chip's actual memory map.

> Binutils calls below use `${CROSS_PREFIX}`, exported by each leaf image
> (`arm-none-eabi-` on the arm leaf, `riscv-none-elf-` on wch). It is empty in
> `embedded-base`, where the host binutils are used instead.

## Steps

1. **Identify the linker script** — look for `*.ld` or `*.lds` in the workspace. If multiple exist, identify which CMakeLists.txt passes via `target_link_options(<target> PRIVATE -T <path>)`.

2. **Find the target memory map** — check the SVD file (`$SVD_FILE`), the chip datasheet, or ask the user for flash start / size and RAM start / size.

3. **Check MEMORY region definitions:**
   ```
   MEMORY {
     FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 1024K   /* must match actual flash */
     RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K    /* must match actual RAM */
   }
   ```
   Flag: wrong `ORIGIN`, undersized `LENGTH`, missing regions (e.g. CCM, backup SRAM, ITCM).

4. **Check SECTIONS ordering and placement:**
   - `.isr_vector` / `.vectors` must be first in FLASH and have `KEEP(*(...))`; without `KEEP` the linker will GC the vector table.
   - `.text` follows, then `.rodata`.
   - `.data` load address (LMA) in FLASH, run address (VMA) in RAM; check that the startup code copies it from `_sdata` to `_edata` using LMA.
   - `.bss` zero-initialised — check that startup zeros from `_sbss` to `_ebss`.
   - `.init_array` / `.fini_array` — MUST be `KEEP`d if C++ global constructors are used. Without `KEEP`, `-Wl,--gc-sections` prunes them silently and global ctors never run.
   - Stack: check `_estack` is set to top of RAM (RAM origin + length); `PROVIDE(_estack = ...)` pattern.
   - Heap (if used): `_heap_start` and `_heap_end` must not overlap stack.

5. **Check symbol exports** needed by startup code:
   - `_sdata`, `_edata`, `_sidata` (LMA of .data)
   - `_sbss`, `_ebss`
   - `_estack`
   - `__init_array_start`, `__init_array_end` (for `__libc_init_array`)

6. **Verify against build output:**
   ```bash
   ${CROSS_PREFIX}size build/firmware.elf
   ${CROSS_PREFIX}objdump -h build/firmware.elf | head -30
   ```
   Check that `.text + .data` fits in flash, `.data + .bss + stack` fits in RAM.

## Common issues

| Issue | Symptom | Fix |
|---|---|---|
| Missing `KEEP` on `.isr_vector` | Hard fault at boot — wrong PC after reset | Add `KEEP(*(.isr_vector))` |
| Missing `KEEP` on `.init_array` | Global C++ objects never constructed | Add `KEEP(*(SORT(.init_array.*))) KEEP(*(.init_array))` |
| `_sidata` missing or wrong | `.data` not initialised (reads as garbage) | `_sidata = LOADADDR(.data)` |
| Stack overlaps heap or `.bss` | Stack corruption under load | Grow MEMORY LENGTH or reduce heap |
| Wrong ORIGIN for the actual part | Code runs on eval board but fails on production part | Cross-check SVD / datasheet |
