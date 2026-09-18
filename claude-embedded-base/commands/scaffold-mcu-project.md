Create a C++ embedded project scaffold. Arguments: $ARGUMENTS

Usage: `/scaffold-mcu-project <arm|wch|telink> [part-number]`
Examples: `/scaffold-mcu-project arm STM32WBA65RI`, `/scaffold-mcu-project arm STM32F407VG`, `/scaffold-mcu-project wch CH32V003F4P6`

## Steps

### 1. Validate

If the first argument is not `arm`, `wch` or `telink`, print the valid options and stop.

If no part number is given, **ask for one before generating anything.** The core,
FPU, memory map, flash tool and SVD all derive from it, and a scaffold built
without it produces a binary for the wrong CPU that still links cleanly. Do not
guess a default.

### 2. Resolve the part

For `arm`, determine from the part number (use the `stm32-part-lookup` skill if
present, otherwise the datasheet / your own knowledge):

- **Core** — `cortex-m0plus`, `cortex-m3`, `cortex-m4`, `cortex-m7`, `cortex-m33`
- **FPU / float ABI** — e.g. M4F → `fpv4-sp-d16` + `hard`; M33 with FPU → `fpv5-sp-d16` + `hard`; M0+ → `none` + `soft`
- **Flash and RAM origin + size**
- **Flash tool** — see the table below
- **TrustZone** — whether the part has it (all STM32L5/U5/H5/WBA)

Flash-tool selection for STM32:

| Family | Tool | Why |
| --- | --- | --- |
| F0/F1/F2/F3/F4/F7, G0/G4, L0/L1/L4, WB55, WL | `openocd` | Supported by OpenOCD 0.12 |
| **WBA5x, WBA6x (incl. WBA65), U5, H5, C0, U0, N6** | **`probe-rs`** | OpenOCD 0.12 does not know these parts. WBA65 in particular fails with `auto_probe failed`. |
| Anything brand new | `pyocd` + `pyocd pack install <part>`, or STM32CubeCLT | CMSIS-Pack tracks new silicon fastest |

### 3. Create the VSCode wiring

```bash
mkdir -p .vscode cmake src test/host
cp /opt/embedded/vscode-templates/tasks.json  .vscode/tasks.json
cp /opt/embedded/vscode-templates/launch.json .vscode/launch.json
cp /opt/embedded/profile.json                 .mcu-profile.json
```

### 4. Fill in the profile

Edit `.mcu-profile.json` for the resolved part. The full key reference is
`mcu --schema` (or `/opt/embedded/profile.schema.json`). At minimum set
`chip`, `core`, `fpu`, `floatAbi`, `flashTool`, and the `sizeBudget` from the
part's real flash/RAM figures.

For a probe-rs part (e.g. STM32WBA65RI):

```jsonc
{
  "chip": "STM32WBA65RI",
  "core": "cortex-m33",
  "fpu": "fpv5-sp-d16",
  "floatAbi": "hard",
  "probe": "stlink",
  "flashTool": "probe-rs",
  "ELF": "build/firmware.elf",
  "sizeBudget": { "flash": 2097152, "ram": 524288 },
  "flash":       "probe-rs download --chip ${chip} --binary-format elf ${ELF}",
  "erase":       "probe-rs erase --chip ${chip}",
  "reset":       "probe-rs reset --chip ${chip}",
  "debugServer": "probe-rs gdb --chip ${chip} --gdb-connection-string 0.0.0.0:3333",
  "rtt":         "probe-rs attach --chip ${chip} ${ELF}",
  "postBuild":   ["size"]
}
```

Then find an SVD:

```bash
svd-find --set <part>          # searches /opt/svd and writes SVD_FILE
svd-find --pack <part>         # falls back to the CMSIS-Pack index
mcu --export                   # regenerate .vscode/.profile.env for launch.json
```

### 5. Generate the build

**`cmake/toolchain.cmake`** — the core-specific flags go HERE, not in
`CMakeLists.txt`, so they apply to the compiler probe as well:

```cmake
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   arm-none-eabi-gcc)
set(CMAKE_CXX_COMPILER arm-none-eabi-g++)
set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)
set(CMAKE_OBJCOPY      arm-none-eabi-objcopy)
set(CMAKE_SIZE         arm-none-eabi-size)

# Substitute the resolved core/FPU. For a soft-float core drop the two
# -mfpu/-mfloat-abi flags entirely and use -mfloat-abi=soft.
set(ARCH_FLAGS "-mcpu=<CORE> -mthumb -mfpu=<FPU> -mfloat-abi=<ABI>")

set(CMAKE_C_FLAGS_INIT          "${ARCH_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT        "${ARCH_FLAGS}")
set(CMAKE_ASM_FLAGS_INIT        "${ARCH_FLAGS} -x assembler-with-cpp")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${ARCH_FLAGS}")

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
```

**`CMakeLists.txt`:**

```cmake
cmake_minimum_required(VERSION 3.20)
project(firmware CXX C ASM)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Native unit tests for hardware-independent code — no toolchain file, separate
# build dir:  cmake -S . -B build-host -G Ninja -DHOST_TESTS=ON
option(HOST_TESTS "Build native unit tests instead of firmware" OFF)
if(HOST_TESTS)
    include(/opt/embedded/cmake/host-test.cmake)
    add_host_test_suite(logic_tests
        SOURCES    test/host/test_placeholder.cpp
        UNDER_TEST # src/logic/*.cpp
        INCLUDES   src)
    return()
endif()

include(/opt/embedded/cmake/embedded-common.cmake)

add_executable(firmware
    src/main.cpp
    src/startup.cpp
)

target_include_directories(firmware PRIVATE
    src
    $ENV{CMSIS_DIR}/CMSIS/Core/Include
)

target_link_options(firmware PRIVATE
    -T ${CMAKE_SOURCE_DIR}/linker.ld
)

embedded_hardening(firmware)     # C++20, -fno-exceptions/-rtti, gc-sections, warnings
embedded_artifacts(firmware)     # .hex/.bin + size report after every build
embedded_stack_usage(firmware)   # -fstack-usage, for the stack-usage-estimate skill
```

For `wch`: generate a `ch32v003fun` Makefile scaffold with RISC-V flags, or the
CMake equivalent using `/opt/embedded/cmake/riscv-toolchain.cmake` if present.

For `telink`: tc32 uses a custom Makefile — generate a minimal one pointing at
`/opt/telink/sdk/tools/tc32`, and check the SDK is actually mounted first.

### 6. Device headers, startup and linker script

For **`arm` + STM32**: the image ships ST's CMSIS device headers under
`$STM32_CMSIS_DIR` (Apache-2.0, no HAL). Wire them up rather than hand-writing:

```bash
ls $STM32_CMSIS_DIR                                  # available families
cp $STM32_CMSIS_DIR/<family>/Source/Templates/gcc/startup_<part>.s src/
cp $STM32_CMSIS_DIR/<family>/Source/Templates/gcc/linker/*.ld      linker.ld
```

Add `-I$STM32_CMSIS_DIR/<family>/Include` and define the part macro
(e.g. `-DSTM32WBA65xx`). Verify `linker.ld`'s `MEMORY` block against the real
part — the ST templates are per-family and often need the sizes adjusting.

If no template exists, write `src/startup.cpp` using the
`cortex-m-startup-cpp` skill — in particular the `.init_array` loop, without
which no global C++ constructor ever runs.

### 7. `src/main.cpp`

```cpp
// Bare-metal entry point. Startup code has already copied .data, zeroed .bss
// and run global C++ constructors before reaching here.
int main() {
    // 1. Enable the clock for the GPIO port
    // 2. Configure the pin as push-pull output
    // 3. Toggle in a loop
    for (;;) {
    }
}
```

### 8. Verify before declaring success

Run these and report the actual output — do not assume:

```bash
mcu --list                 # profile parsed, tasks visible
mcu build                  # compiles and links
mcu size                   # fits the declared budget
/probe-detect              # probe visible in the container
```

Confirm the binary is for the right core:

```bash
${CROSS_PREFIX}readelf -A build/firmware.elf | grep -E 'Tag_CPU_name|Tag_CPU_arch|Tag_FP_arch'
```

### 9. Print next steps

- Any `<CORE>`/`<FPU>`/`<ABI>` placeholders still left in `cmake/toolchain.cmake`
- Whether `linker.ld` was templated or still needs the memory map filled in
- Whether an SVD was found, or `svd-find --pack` is still needed
- For a TrustZone part: the option bytes are untouched, and **the `stm32-option-bytes` skill
  must be consulted before any attempt to change `TZEN` or `RDP`**
