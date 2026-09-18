# Hard Fault Decode

Turn a Cortex-M fault into a named cause and a source line. Works from a live
GDB session, from a serial/RTT fault dump, or from raw register values pasted by
the user.

For RISC-V targets see the `mcause` table at the end.

## Step 0: What you need

Minimum: the fault status registers and the stacked PC.
Ideal: the `.elf` that produced the fault, so symbols resolve.

| Register | Address | Meaning |
| --- | --- | --- |
| `CFSR`  | `0xE000ED28` | Configurable Fault Status (MMFSR/BFSR/UFSR packed) |
| `HFSR`  | `0xE000ED2C` | HardFault Status |
| `DFSR`  | `0xE000ED30` | Debug Fault Status |
| `MMFAR` | `0xE000ED34` | MemManage Fault Address |
| `BFAR`  | `0xE000ED38` | BusFault Address |
| `AFSR`  | `0xE000ED3C` | Auxiliary Fault Status (vendor-specific) |

## Step 1: Read them

In a live GDB session:

```gdb
set $cfsr  = *(unsigned int *) 0xE000ED28
set $hfsr  = *(unsigned int *) 0xE000ED2C
set $mmfar = *(unsigned int *) 0xE000ED34
set $bfar  = *(unsigned int *) 0xE000ED38
printf "CFSR=%08x HFSR=%08x MMFAR=%08x BFAR=%08x\n", $cfsr, $hfsr, $mmfar, $bfar
```

Or via openocd/probe-rs without GDB:

```bash
# openocd
openocd -f "$OPENOCD_INTERFACE" -f "$OPENOCD_TARGET" \
    -c "init; halt; mdw 0xE000ED28 4; exit"

# probe-rs
probe-rs read --chip "$chip" b32 0xE000ED28 4
```

## Step 2: Decode CFSR

`CFSR` is three registers in one word.

### UsageFault — bits 31:16

| Bit | Name | Meaning |
| --- | --- | --- |
| 25 | `DIVBYZERO` | Divide by zero with `DIV_0_TRP` enabled |
| 24 | `UNALIGNED` | Unaligned access with `UNALIGN_TRP` enabled, or any unaligned `LDM`/`STM`/`LDRD`/`STRD` |
| 19 | `NOCP` | Coprocessor access — **almost always a floating-point instruction with the FPU not enabled.** See the `cortex-m-fpu-enable` skill. |
| 18 | `INVPC` | Invalid `EXC_RETURN` / integrity check failure on exception return |
| 17 | `INVSTATE` | **Thumb bit missing.** Branch to an address with bit 0 clear — a corrupted function pointer, a vector table entry written without `\|1`, or a jump into data. |
| 16 | `UNDEFINSTR` | Undefined instruction — executing data, or an instruction the core does not implement (e.g. a DSP/FPU instruction on an M0+) |

### BusFault — bits 15:8

| Bit | Name | Meaning |
| --- | --- | --- |
| 15 | `BFARVALID` | `BFAR` holds the faulting address — **check this before trusting BFAR** |
| 13 | `LSPERR` | Fault during lazy FP state preservation |
| 12 | `STKERR` | Fault stacking on exception entry — **stack overflow**, see `stack-usage-estimate` |
| 11 | `UNSTKERR` | Fault unstacking on exception return |
| 10 | `IMPRECISERR` | **Asynchronous** — the stacked PC is NOT the culprit. See Step 4. |
| 9 | `PRECISERR` | Synchronous; stacked PC is the faulting instruction, `BFAR` is the address |
| 8 | `IBUSERR` | Instruction fetch from an invalid address |

### MemManage — bits 7:0

| Bit | Name | Meaning |
| --- | --- | --- |
| 7 | `MMARVALID` | `MMFAR` holds the faulting address |
| 5 | `MLSPERR` | MPU fault during lazy FP preservation |
| 4 | `MSTKERR` | MPU fault stacking on exception entry |
| 3 | `MUNSTKERR` | MPU fault unstacking |
| 1 | `DACCVIOL` | Data access violated an MPU region |
| 0 | `IACCVIOL` | Instruction fetch violated an MPU region (often an XN region) |

### HFSR

| Bit | Name | Meaning |
| --- | --- | --- |
| 31 | `DEBUGEVT` | Debug event |
| 30 | `FORCED` | **A configurable fault escalated to HardFault** — decode CFSR, that is the real cause |
| 1 | `VECTTBL` | Fault reading the vector table — bad `VTOR` or a corrupt table |

`HFSR = 0x40000000` with `CFSR = 0` means the fault escalated because the
relevant handler is disabled. Enable them so faults land precisely:

```cpp
SCB->SHCSR |= SCB_SHCSR_USGFAULTENA_Msk
            | SCB_SHCSR_BUSFAULTENA_Msk
            | SCB_SHCSR_MEMFAULTENA_Msk;
```

## Step 3: Find the stacked frame

On exception entry the core pushes 8 words. `EXC_RETURN` in `LR` says where:

| `LR` bit 2 | Stack used |
| --- | --- |
| 0 | MSP |
| 1 | PSP |

```
offset  0   4   8   12  16  20  24   28
        R0  R1  R2  R3  R12 LR  PC   xPSR
```

A minimal handler that hands the frame to C++:

```cpp
extern "C" __attribute__((naked)) void HardFault_Handler() {
    __asm volatile(
        "tst   lr, #4            \n"  // which stack was in use?
        "ite   eq                \n"
        "mrseq r0, msp           \n"
        "mrsne r0, psp           \n"
        "mov   r1, lr            \n"
        "b     hardfault_report  \n"
    );
}

extern "C" void hardfault_report(uint32_t* frame, uint32_t exc_return) {
    const uint32_t stacked_pc   = frame[6];
    const uint32_t stacked_lr   = frame[5];
    const uint32_t stacked_xpsr = frame[7];
    const uint32_t cfsr = SCB->CFSR;
    const uint32_t hfsr = SCB->HFSR;
    const uint32_t bfar = SCB->BFAR;
    const uint32_t mmfar = SCB->MMFAR;
    (void) exc_return; (void) stacked_lr; (void) stacked_xpsr;
    (void) cfsr; (void) hfsr; (void) bfar; (void) mmfar; (void) stacked_pc;
    // print via RTT/UART, or just break so a debugger catches it:
    __asm volatile("bkpt #0");
    for (;;) {}
}
```

In GDB, read the frame directly:

```gdb
set $frame = ($lr & 4) ? $psp : $msp
printf "PC=%08x LR=%08x xPSR=%08x\n", ((unsigned int*)$frame)[6], \
       ((unsigned int*)$frame)[5], ((unsigned int*)$frame)[7]
```

## Step 4: Symbolise

```bash
ELF="${ELF:-build/firmware.elf}"
PC=0x08001234

# Function + file:line
${CROSS_PREFIX}addr2line -f -C -e "$ELF" $PC

# Disassemble around it — the faulting instruction and its neighbours
${CROSS_PREFIX}objdump -d -C --start-address=$((PC - 32)) --stop-address=$((PC + 32)) "$ELF"
```

Also symbolise the stacked `LR` — that is the caller, and it usually says more
about *why* than the `PC` does.

> **`IMPRECISERR` set:** the stacked PC is wrong, because the write that faulted
> retired from the store buffer later. Reproduce with the buffer disabled so the
> fault becomes synchronous:
> ```cpp
> SCB->ACTLR |= SCB_ACTLR_DISDEFWBUF_Msk;   // Cortex-M3/M4 only
> ```
> Costs performance; use it only while hunting the bug.

## Step 5: Common causes, ranked

| Symptom | Cause to check first |
| --- | --- |
| `NOCP` | FPU not enabled before a float op. `cortex-m-fpu-enable`. Frequently a `float` in an ISR, or `printf("%f")`. |
| `INVSTATE` | Function pointer corrupted, or a vector table entry without the Thumb bit. `cortex-m-vector-table`. |
| `STKERR` + SP near the RAM floor | Stack overflow. `stack-usage-estimate`. |
| `PRECISERR` + `BFAR` in an unmapped window | Peripheral accessed with its clock gated — the single most common STM32 hard fault. |
| `PRECISERR` + `BFAR = 0x00000000` | Null pointer dereference; often an uninitialised global used before `.init_array` ran. `cortex-m-startup-cpp`. |
| `IACCVIOL` / fault immediately after reset | Bad `_estack`, `.isr_vector` misplaced, or `VTOR` wrong. `linker-script-audit`. |
| `UNDEFINSTR` on an M0/M0+ | Code built for a higher core — check `-mcpu` matches the silicon. |
| Fault only with optimisation on | Missing `volatile` on an MMIO or ISR-shared variable, or a strict-aliasing violation. |

## Step 6: Report

State, in this order:

1. The decoded fault type and the exact bit that was set.
2. The symbolised faulting location (`function` at `file:line`) and the caller.
3. The specific cause, from the table above.
4. The concrete fix.
5. Whether `BFARVALID`/`MMARVALID` were set — if not, say the fault address is
   not trustworthy rather than reasoning from a stale value.

## RISC-V: `mcause`

| `mcause` | Meaning |
| --- | --- |
| 0 | Instruction address misaligned |
| 1 | Instruction access fault |
| 2 | Illegal instruction |
| 3 | Breakpoint |
| 4 | Load address misaligned |
| 5 | Load access fault |
| 6 | Store/AMO address misaligned |
| 7 | Store/AMO access fault |
| 11 | Environment call from M-mode |

Read `mepc` for the faulting PC and `mtval` for the offending address, then
symbolise with `addr2line` exactly as above.

```gdb
info registers mcause mepc mtval
```
