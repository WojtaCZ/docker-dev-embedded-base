# C++ Embedded Conventions

Apply these rules when writing or reviewing C++ code for bare-metal embedded targets in this project.

## Compiler flags (enforce in CMakeLists.txt)

```cmake
target_compile_options(<target> PRIVATE
    -std=c++20
    -fno-exceptions        # no exception table overhead (~10-20% code size on Cortex-M)
    -fno-rtti              # no dynamic_cast / typeid overhead
    -fno-threadsafe-statics  # no mutex around local static init (no OS, no concurrency concern here)
    -ffunction-sections    # allow linker --gc-sections to prune dead functions
    -fdata-sections        # allow linker --gc-sections to prune dead data
    -Wall -Wextra -Wpedantic
    -Wconversion -Wsign-conversion
)
target_link_options(<target> PRIVATE
    -Wl,--gc-sections      # prune unused sections
    -Wl,-Map,build/firmware.map  # link map for size analysis
)
```

## Preferred patterns

- **`constexpr` first.** Prefer `constexpr` over `#define` for constants. `constexpr` functions over inline functions. Evaluate as much as possible at compile time.
- **No `std::string`, `std::vector`, or other heap-allocating STL containers** in ISR context or on memory-constrained (<64 KB RAM) devices. Use fixed-size arrays, `std::array`, or ETL (`etl::vector`, `etl::string`) when a standard-library-style API is needed without heap allocation.
- **ETL for containers:** `#include <etl/vector.h>` — Embedded Template Library is available in this container as part of the project scaffold. Use it for `etl::vector<T,N>`, `etl::map<K,V,N>`, `etl::queue<T,N>`, etc.
- **Virtual dispatch on tight memory budgets:** Each virtual function adds 4 bytes to the vtable and the class needs a hidden vptr. On parts with <8 KB RAM (MSPM0C1104), avoid virtual unless the polymorphism gain is significant. Use `std::variant` or a manual type-tag instead.
- **`static` local variables** in ISRs: avoided — the thread-safety guard (`__cxa_guard_acquire`) calls OS primitives that don't exist on bare metal. `-fno-threadsafe-statics` disables the guard but doesn't make the pattern safe if the ISR fires during the initialiser. Move to global or file-scope statics instead.
- **Global constructors** (`__attribute__((constructor))` or non-trivial static storage duration): verified by ensuring the startup code calls `__libc_init_array()` before `main()`. Check the `cortex-m-startup-cpp` skill for the correct startup pattern.

## What to avoid

| Avoid | Why | Alternative |
|---|---|---|
| `new` / `delete` | Heap fragmentation, non-deterministic timing | Static or stack allocation |
| `std::string` | Heap | `char[N]`, `etl::string<N>` |
| Exceptions (`throw`/`try`/`catch`) | Removed by -fno-exceptions — UB to throw | Return codes, `std::expected` (C++23), result types |
| `dynamic_cast` | Requires RTTI | Use type tags / `std::variant` |
| `std::cout` | Links `stdio` sink, pulls in file I/O | Semihosting `printf`, `ITM_SendChar`, custom ring-buffer UART |
| `std::mutex` / `std::thread` | No OS | Disable interrupts, FreeRTOS primitives, or ETL mutex wrappers |

## Checking conformance

```bash
# Size report sorted by object size
arm-none-eabi-nm -C --size-sort --print-size build/firmware.elf | tail -30

# Section sizes
arm-none-eabi-size build/firmware.elf

# Detect heap usage (any call to sbrk/malloc from application code)
arm-none-eabi-nm build/firmware.elf | grep -w '_sbrk\|malloc\|free\|new\|delete'
```
