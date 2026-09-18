
---

## Embedded layer (`docker-dev-embedded-base` and its leaves)

This container has a full bare-metal embedded toolchain. **No vendor HAL** —
this fleet writes register-level C++20 against CMSIS headers.

| Area | What is here |
|---|---|
| Debug / flash | `openocd`, `probe-rs`, `pyocd` (+ `cmsis-pack-manager`), `st-info`/`st-flash` (stlink), `dfu-util`, `gdb` (Arch's gdb IS multiarch — there is no `gdb-multiarch`) |
| Build | `cmake`, `ninja`, `make`, `meson`, `ccache` |
| C++ analysis | `clang` (ships `clangd`, `clang-tidy`, `clang-format`, `clang-query` — no separate package), `lld`, `llvm`, `cppcheck` |
| Host-side tests | `gtest`, `catch2`, `gcovr`, `lcov` |
| Serial console | `picocom`, `minicom`, `screen`, `socat`. **`tio` is NOT installed** (AUR-only) |
| USB / ELF | `usbutils` (`lsusb`), `libusb`, `hidapi`, `python-pyelftools`, `python-pyserial` |
| Misc | `dtc`, `rsync`, `fakeroot` |

### Commands to prefer over ad-hoc shell

- **`mcu <key>`** — the project task runner. Reads `.mcu-profile.json` from the
  workspace and runs the command stored under `<key>`. **Use this instead of
  reconstructing cmake/openocd invocations by hand.**
  - Task keys: `build`, `buildDebug`, `clean`, `flash`, `erase`, `reset`,
    `serial`, `debugServer`, `rtt`, `size`, `test`, `hostTest`
  - `mcu --list` shows the keys and settings actually defined here
  - `mcu --print <key>` shows a command without running it
  - `mcu --export` writes scalar keys to `.vscode/.profile.env` for `launch.json`
  - `size` and `test` are built in: `size` enforces `.sizeBudget`; `test`
    flashes, captures target output and asserts on `.testPass`/`.testFail`
  - Caveat: profile command strings run through `bash -c`, i.e. arbitrary code
    execution from workspace content. Deliberate. Do not point it at an
    untrusted repo.
- **`svd-find <part>`** — locate a `.svd` for register-level reasoning. Searches
  the bundled stores, and `svd-find --pack <part>` pulls from ST's CMSIS-Pack
  via pyocd for parts neither store carries.
- **`dev-doctor`** — includes embedded checks (`30-embedded.sh`) on top of the
  baseline ones.

### Paths and env vars

| Var / path | Meaning |
|---|---|
| `$SVD_STORE` = `/opt/svd` | SVD store. `cmsis-svd-data/` is the multi-vendor set; leaves add vendor mirrors |
| `$PYOCD_HOME` = `/opt/pyocd` | pyocd packs land here (world-writable, so `dev` can install packs) |
| `$CROSS_PREFIX` | Cross-toolchain prefix for this image — `arm-none-eabi-`, `riscv-none-elf-`, `tc32-elf-`. **Empty in embedded-base itself.** Use it instead of hardcoding a triple, so binutils-driven work is portable across leaves |
| `/opt/embedded/cmake/` | Shared CMake helpers (below) |
| `/opt/embedded/vscode-templates/` | `tasks.json` + `launch.json` starters |
| `/opt/embedded/profile.schema.json` | `.mcu-profile.json` schema; also `mcu --schema` |
| `/opt/embedded/udev-rules/` | **Inert here** — udev does not run in a container. Shipped so `install-host-udev-rules.sh` can install them on the HOST. Probe permission problems are a host-side fix |

### Shared CMake helpers

`include(/opt/embedded/cmake/embedded-common.cmake)` (has an `include_guard`,
safe to include repeatedly) provides:

- `embedded_hardening(<target>)` — the fleet's standard bare-metal C++ flags:
  C++20, no exceptions/RTTI/threadsafe-statics, `-ffunction-sections`
  `-fdata-sections` + `--gc-sections`, a warning set including `-Wconversion`
  and `-Wdouble-promotion`, a linker map and `--print-memory-usage`,
  `nano.specs`/`nosys.specs`. Call this rather than hand-rolling flags.
- `find_cmsis_dsp(<core> <outvar>)` — ARM leaf only; see the ARM layer.

`/opt/embedded/cmake/host-test.cmake` covers host-side unit tests.

### Skills in this layer

`clock-tree-derive` · `cpp-embedded-conventions` · `cpp-template-bloat-audit` ·
`firmware-binary-diff` · `gdb-debug-session` · `hardfault-decode` ·
`interrupt-priority-audit` · `linker-script-audit` · `probe-troubleshoot` ·
`register-decode-svd` · `stack-usage-estimate`

Commands: `/probe-detect`, `/scaffold-mcu-project`.
MCP added by this layer: `fetch`.

`cpp-embedded-conventions` is the written form of what `embedded_hardening()`
enforces — read it before writing new firmware C++ so the docs and the build
agree. The binutils-driven skills (`firmware-binary-diff`,
`cpp-template-bloat-audit`, `stack-usage-estimate`, `hardfault-decode`) rely on
`$CROSS_PREFIX`.
