Create a minimal C++ embedded project scaffold for the MCU target: $ARGUMENTS

Valid targets: `arm`, `wch`, `telink`

Steps:

1. **Validate the target.** If $ARGUMENTS is not one of arm/wch/telink, print the valid options and stop.

2. **Create the .vscode directory** if it does not exist:
   ```bash
   mkdir -p .vscode
   ```

3. **Copy tasks.json and launch.json from the base image templates:**
   ```bash
   cp /opt/embedded/vscode-templates/tasks.json  .vscode/tasks.json
   cp /opt/embedded/vscode-templates/launch.json .vscode/launch.json
   ```

4. **Copy the leaf's default profile:**
   ```bash
   cp /opt/embedded/profile.json .mcu-profile.json
   ```

5. **Generate a CMakeLists.txt scaffold** for the target. Use the appropriate toolchain file and flags:

   For `arm`:
   ```cmake
   cmake_minimum_required(VERSION 3.20)
   project(firmware CXX ASM)

   set(CMAKE_CXX_STANDARD 20)
   set(CMAKE_CXX_EXTENSIONS OFF)

   # Toolchain is set by cmake/arm-none-eabi.cmake via -DCMAKE_TOOLCHAIN_FILE
   # Run: cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/arm-none-eabi.cmake

   add_executable(firmware
       src/main.cpp
       src/startup.cpp    # user-supplied startup for the specific chip
   )

   target_compile_options(firmware PRIVATE
       -fno-exceptions
       -fno-rtti
       -fno-threadsafe-statics
       -ffunction-sections
       -fdata-sections
       -Wall -Wextra
   )

   target_link_options(firmware PRIVATE
       -T ${CMAKE_SOURCE_DIR}/linker.ld   # user-supplied linker script
       -Wl,--gc-sections
       -Wl,-Map,${CMAKE_BINARY_DIR}/firmware.map
       --specs=nosys.specs
   )

   set_target_properties(firmware PROPERTIES OUTPUT_NAME "firmware")

   # CMSIS headers (from base image)
   target_include_directories(firmware PRIVATE $ENV{CMSIS_DIR}/CMSIS/Core/Include)

   # Generate compile_commands.json for clangd
   set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
   ```

   Also create `cmake/arm-none-eabi.cmake`:
   ```cmake
   set(CMAKE_SYSTEM_NAME Generic)
   set(CMAKE_SYSTEM_PROCESSOR arm)

   set(CMAKE_C_COMPILER   arm-none-eabi-gcc)
   set(CMAKE_CXX_COMPILER arm-none-eabi-g++)
   set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)
   set(CMAKE_OBJCOPY      arm-none-eabi-objcopy)
   set(CMAKE_SIZE         arm-none-eabi-size)

   set(CMAKE_C_FLAGS_INIT   "-mthumb")
   set(CMAKE_CXX_FLAGS_INIT "-mthumb")
   set(CMAKE_ASM_FLAGS_INIT "-mthumb -x assembler-with-cpp")
   set(CMAKE_EXE_LINKER_FLAGS_INIT "-mthumb")

   set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
   ```

   For `wch`: generate a Makefile scaffold using `ch32v003fun` with RISC-V flags.

   For `telink`: note that tc32 uses a custom Makefile; generate a minimal Makefile pointing at the tc32 toolchain in the mounted SDK.

6. **Create src/main.cpp** with a minimal bare-metal blinky comment skeleton:
   ```cpp
   // Bare-metal entry point. Startup code calls this after .data/.bss init
   // and __libc_init_array (global C++ constructors).
   int main() {
       // 1. Enable clocks for the GPIO port you want to blink
       // 2. Configure the pin as push-pull output
       // 3. Toggle in a loop
       for (;;) {
           // toggle pin
           // delay
       }
   }
   ```

7. **Print next steps:**
   - Edit `.mcu-profile.json` to set the correct openocd target config for your chip (e.g. `target/stm32f4x.cfg`, `target/rp2040.cfg`, `target/ti_mspm0.cfg`).
   - Set `OPENOCD_INTERFACE` in `.mcu-profile.json` (default is `interface/stlink.cfg`; use `interface/cmsis-dap.cfg` for BMP in CMSIS-DAP mode or `interface/blackmagic.cfg` for BMP native).
   - Set `SVD_FILE` to the path of your chip's `.svd` file for register decoding and peripheral viewer.
   - For ARM: add your chip's startup file (`src/startup.cpp`) and linker script (`linker.ld`).
   - Run `/probe-detect` to verify your debug probe is visible in the container.
   - Run the `Build` task (Ctrl+Shift+B) to verify the toolchain is working.
