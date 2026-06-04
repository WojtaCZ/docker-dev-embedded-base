# Interrupt Priority Audit

Audit NVIC priority configuration in the codebase for ARM Cortex-M targets, or PLIC configuration for RISC-V targets.

## ARM Cortex-M (NVIC)

### Collect all priority assignments

Search for calls to `NVIC_SetPriority`, `HAL_NVIC_SetPriority`, or direct writes to `NVIC->IP[n]` or `SCB->SHP[n]`:

```bash
grep -rn "NVIC_SetPriority\|HAL_NVIC_SetPriority\|NVIC->IP\|SCB->SHP\|__NVIC_SetPriority" --include="*.cpp" --include="*.hpp" --include="*.c" --include="*.h" .
```

### Check the priority group configuration

Find calls to `NVIC_SetPriorityGrouping` or `HAL_NVIC_SetPriorityGrouping`. The grouping determines how many bits are preemption vs. sub-priority. Mismatched grouping is the most common source of priority confusion.

```bash
grep -rn "SetPriorityGrouping\|NVIC_PriorityGroup" --include="*.c" --include="*.cpp" .
```

### Check `__NVIC_PRIO_BITS`

From the device header (e.g. `stm32f4xx.h`, `MSPM0C1104.h`): how many priority bits does this Cortex-M implementation have? Common values: 2 (Cortex-M0/M0+), 3 (some M3), 4 (STM32 M3/M4).

A priority value of `5` on a Cortex-M0+ (2 bits, effective priorities 0/64/128/192) is meaningless — document the hardware limit clearly.

### RTOS considerations (FreeRTOS)

FreeRTOS requires that any ISR calling `FromISR` API functions uses a priority **numerically higher** (lower urgency) than `configMAX_SYSCALL_INTERRUPT_PRIORITY`. Check:
- `configMAX_SYSCALL_INTERRUPT_PRIORITY` / `configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY` in `FreeRTOSConfig.h`
- Any ISR that calls `xQueueSendFromISR`, `xSemaphoreGiveFromISR`, `portYIELD_FROM_ISR`, etc. — these must NOT have a numerically lower (higher urgency) priority than the syscall ceiling.

### Output format

Produce a table:

| IRQ name | Priority value | Preemption bits | Effective priority | RTOS-safe? | Issue |
|---|---|---|---|---|---|
| USART1_IRQn | 5 | 4 | 5 | Yes | — |
| DMA1_Stream0_IRQn | 0 | 4 | 0 | No — higher than syscall ceiling | Should be ≥ configMAX_SYSCALL |

## RISC-V (PLIC / CLIC on CH32V)

For WCH CH32V003/V203 using the QingKe RISC-V core:
```bash
grep -rn "PFIC\|NVIC_SetPriority\|NVIC_EnableIRQ\|__enable_irq\|__disable_irq\|mstatus\|mie\b\|PFIC_EnableIRQ" --include="*.c" --include="*.cpp" .
```

Flag any ISR that modifies global interrupt enable (`mstatus.MIE`) — re-entrant ISRs on a single-core RISC-V with no preemption are unusual and risky.
