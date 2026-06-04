# C++ Template Bloat Audit

Find template instantiation explosions that inflate binary size on resource-constrained targets.

## Step 1: Sort symbols by size

```bash
arm-none-eabi-nm -C --size-sort --print-size build/firmware.elf \
    | grep " T \| t " \
    | tail -40
```

Look for many similarly-named symbols differing only by template argument (e.g. `Gpio<GPIOA, 5>`, `Gpio<GPIOB, 3>` each generating separate code).

## Step 2: Check map file for repeated patterns

```bash
grep -E "<[A-Z]" build/firmware.map | sort | uniq -c | sort -rn | head -20
```

A large count for a template instantiation suggests the compiler is not sharing code across instantiations that could share it.

## Step 3: Identify the heavy hitters

```bash
# Total text size contributed by each translation unit
arm-none-eabi-objdump -t build/firmware.elf \
    | awk '/\.text/ {sum[$NF]+=$5} END {for(f in sum) printf "%8d  %s\n", sum[f], f}' \
    | sort -rn | head -20
```

## Step 4: Apply fixes

### `extern template` to suppress implicit instantiation

If a template is instantiated with a fixed set of types, declare explicit instantiations in one `.cpp` file and suppress implicit ones everywhere else:

```cpp
// gpio.hpp
extern template class Gpio<GpioA, 5>;   // suppress implicit instantiation
extern template class Gpio<GpioB, 3>;

// gpio.cpp
template class Gpio<GpioA, 5>;          // one explicit instantiation per type
template class Gpio<GpioB, 3>;
```

### De-template the type-independent parts

```cpp
// Before: entire class is templated → each Pin type = separate code
template<typename Port, uint8_t Pin>
class Gpio { void toggle() { Port::ODR ^= (1 << Pin); } };

// After: type-dependent part is minimal; bulk of code is a non-template base
class GpioBase {
protected:
    volatile uint32_t* const odr_;
    const uint8_t pin_;
    GpioBase(volatile uint32_t* odr, uint8_t pin) : odr_(odr), pin_(pin) {}
public:
    void toggle() { *odr_ ^= (1U << pin_); }  // shared code, not duplicated
};

template<typename Port, uint8_t Pin>
struct Gpio : GpioBase {
    Gpio() : GpioBase(&Port::ODR, Pin) {}
};
```

### Use `if constexpr` instead of full specialisation for small branches

```cpp
template<typename T>
void serialize(T val) {
    if constexpr (sizeof(T) == 1) { uart_put(static_cast<uint8_t>(val)); }
    else if constexpr (sizeof(T) == 2) { uart_put16(static_cast<uint16_t>(val)); }
    else { /* ... */ }
}
```

## Benchmark

After each change: `arm-none-eabi-size build/firmware.elf` — compare `.text` before and after.
