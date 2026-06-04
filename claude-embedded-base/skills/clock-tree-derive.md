# Clock Tree Derivation

Read the clock initialisation code and produce a plain-text clock-tree diagram showing every peripheral's derived clock frequency.

## Steps

1. **Find clock init code.** Search for common patterns:
   ```bash
   grep -rn "SystemClock_Config\|SystemInit\|RCC_\|CLK_\|CLKCTL\|sysctl\|clock_config\|pll" \
       --include="*.cpp" --include="*.c" -l . | head -10
   ```
   Open the most relevant file.

2. **Identify the oscillator source.** Look for HSE (external crystal), HSI (internal RC), or LSE/LSI. Note the frequency — HSE is almost never in the register; it is defined by the board (check `HSE_VALUE` define or the schematic note).

3. **Trace the PLL.** Extract M, N, P, Q dividers (STM32 pattern):
   - `SYSCLK = (HSE / PLLM) * PLLN / PLLP`
   - Verify against the chip's maximum SYSCLK.

4. **Trace AHB/APB bus dividers.** HPRE → PPRE1 → PPRE2 (STM32), or equivalent for the target chip.

5. **List peripheral bus assignments.** For each peripheral mentioned in the code, state which bus it sits on and the resulting clock frequency.

6. **Output format:**
```
OSC source : HSE  = 8 MHz
PLL        : M=4, N=168, P=2  →  SYSCLK = 168 MHz
AHB (HPRE=1)                  →  HCLK   = 168 MHz
APB1 (PPRE1=4)                →  PCLK1  =  42 MHz   (TIM x2 = 84 MHz)
APB2 (PPRE2=2)                →  PCLK2  =  84 MHz   (TIM x2 = 168 MHz)
SysTick                        →           168 MHz
USART2 (on APB1)               →  PCLK1  =  42 MHz
SPI1   (on APB2)               →  PCLK2  =  84 MHz
I2C1   (on APB1)               →  PCLK1  =  42 MHz
ADC    (prescaler /4 from APB2)→            21 MHz
```

7. **Flag any issues:**
   - Clock frequency exceeds the chip's rated max for that peripheral.
   - Missing `__HAL_RCC_xxx_CLK_ENABLE()` calls before peripheral init.
   - PLL not locked before switching source (`PLLRDY` flag not checked).

## RISC-V (CH32V)

For WCH CH32V003:
```bash
grep -rn "SystemInit\|RCC_PLLSource\|SYSCLK_Freq\|HSI\|PLL" --include="*.c" --include="*.cpp" . | head -20
```
CH32V003 runs up to 48 MHz from the internal 24 MHz HSI × PLL; trace `RCC_PLLSource_HSI_Div2` → × 2 → SYSCLK path.
