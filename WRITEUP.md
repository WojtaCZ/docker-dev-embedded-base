# docker-dev-embedded-base — Functional Writeup

> This is the **fleet reference document**. It covers the shared architecture of
> all six `docker-dev-*` repos, then this image in detail.
> Per-image notes: [`template`](../docker-dev-template/WRITEUP.md) ·
> [`arm`](../docker-dev-embedded-arm/WRITEUP.md) ·
> [`wch`](../docker-dev-embedded-wch/WRITEUP.md) ·
> [`telink`](../docker-dev-embedded-telink/WRITEUP.md) ·
> [`web`](../docker-dev-web/WRITEUP.md)

> **Note:** the analysis below describes the repo *as it was audited* on
> 2026-09-02. Every defect listed has since been fixed and every proposal
> implemented — see **Status: implemented** at the end for the mapping. The
> analysis is kept because it records *why* the current design is the way it is.


---

## Part I — The system as a whole

### 1. What the fleet is

A set of Docker images for **AI-driven embedded development**. The unifying idea:
Claude Code runs unattended inside a container that already contains every
toolchain, probe driver, and domain skill it needs, so the container boundary —
not an interactive permission prompt — is the safety envelope.

Three properties fall out of that:

1. **Auth is shared, knowledge is not.** One host login serves every container,
   but an ARM container only ever sees ARM skills. A container cannot suggest a
   `wlink` command on an STM32 project because `wlink` skills are not in its image.
2. **Architecture is a leaf concern.** Everything reusable (probes, GDB, C++
   analysis, build systems, VSCode wiring) lives here in `embedded-base`; only
   cross-compilers and vendor SDKs live in the leaves.
3. **Projects are configuration, not code.** A single JSON file in the workspace
   (`.mcu-profile.json`) parameterises build/flash/erase/reset/debug, so the same
   `tasks.json` works on every chip.

### 2. Inheritance graph

```
archlinux:latest
  └── docker-dev-template                    Arch + dev user + Claude Code
       ├── docker-dev-embedded-base          ← THIS IMAGE. Probes, GDB, C++ tools,
       │    │                                  VSCode templates, 10 skills, 2 commands.
       │    │                                  Deliberately contains NO compiler.
       │    ├── docker-dev-embedded-arm      + arm-none-eabi-g++, CMSIS_6, CMSIS-DSP
       │    └── docker-dev-embedded-wch      + riscv-none-elf-g++, ch32v003fun
       ├── docker-dev-embedded-telink        + tc32 (host-mounted SDK), lib32-glibc
       └── docker-dev-web                    + PHP, Bun, Deno, Playwright, Chromium
```

Telink branches off the template rather than this image because the tc32
toolchain is a 32-bit binary blob needing `lib32-glibc` + multilib; that weight
stays out of the shared base. The cost is duplication — Telink re-copies
`udev-rules/`, `run-profile-task.sh`, and `vscode-templates/` from here.

### 3. The three cross-cutting mechanisms

#### 3.1 Claude config layering

Each image `COPY`s its own `claude-*/` directory over `~/.claude/`:

| Layer | skills | commands | agents | settings.json |
| --- | --- | --- | --- | --- |
| template | (empty) | (empty) | (empty) | 4 baseline MCPs |
| embedded-base | **10** | **2** | (empty) | + `fetch` |
| arm | +5 (merged) | inherited | inherited | replaces (same 5) |
| wch | +3 (merged) | inherited | inherited | replaces (same 5) |
| telink | +2 (merged) | — | — | replaces |

`skills/`, `commands/`, `agents/` **merge additively** (same-name files override).
`settings.json` is a **whole-file replacement** — which is why every leaf
re-declares all inherited MCP servers. That is the fleet's main config smell; see
[template §5.1](../docker-dev-template/WRITEUP.md) for the `jq`-merge fix.

#### 3.2 The profile task runner

```
VSCode task  →  /opt/embedded/run-profile-task.sh <key>
                     ↓ jq -re ".<key>" .mcu-profile.json
                exec bash -c "<command string>"
```

`.mcu-profile.json` lives in the workspace and defines the keys `build`,
`buildDebug`, `clean`, `flash`, `erase`, `reset`, `serial`, `debugServer`.
Each leaf ships a default at `/opt/embedded/profile.json`; `/scaffold-mcu-project`
copies it into the workspace as `.mcu-profile.json`.

The payoff: `vscode-templates/tasks.json` is chip-agnostic and identical
everywhere. Changing chips means editing one JSON file, never a task definition.

Commands use `${VAR:-default}` and `${VAR:?error}` shell expansion, so the
profile doubles as its own validation layer — omitting `OPENOCD_TARGET` produces
a readable error instead of a confusing openocd failure.

#### 3.3 Probe passthrough

USB probes reach the container by three coordinated pieces:

1. **Host udev rules** (`udev-rules/`, installed by `scripts/install-host-udev-rules.sh`).
   udev does **not** run inside a container, so the rules here matter only on the
   host — they set group ownership on the `/dev/bus/usb` nodes before the bind mount.
   Rules ship for ST-Link v2 / v2-1 / v3, Black Magic Probe, CMSIS-DAP, J-Link,
   TI XDS110, and WCH-Link.
2. **Container device mapping** — `dev-up.sh` passes `--device=/dev/bus/usb`,
   bind-mounts `/dev/serial/by-id` and `/sys/bus/usb`, and optionally a specific
   `DEV_PROBE` TTY.
3. **Group alignment** — the image adds `dev` to `dialout,uucp,tty,plugdev,lock`;
   `dev-up.sh` additionally resolves the *host's* numeric `dialout`/`plugdev` GIDs
   and passes them via `--group-add`, because the numeric GIDs differ between the
   Arch container and the host distro.

A consequence worth knowing: the USB bind mount is resolved at container start,
so **a probe plugged in after `dev-up.sh` will not appear**. Restart the container.

---

## Part II — This image

### 4. What `embedded-base` implements

| Category | Contents |
| --- | --- |
| Probe / flash | `openocd`, `stlink` (st-info/st-flash), `pyocd`, `probe-rs`, `picotool`, `wlink`, Black Magic Probe CLI |
| Debug | `gdb-multiarch` |
| C++ analysis | `clang`, `lld`, `llvm`, `clang-tools-extra` (clangd/clang-tidy/clang-format), `cppcheck` |
| Build | `cmake`, `ninja`, `make`, `dtc` |
| Serial | `picocom`, `tio`, `screen`, `minicom` |
| USB | `usbutils`, `libusb`, `libusb-compat`, `hidapi` |
| AUR | `paru-bin` helper, built as a throwaway `aurbuild` user |
| Claude | 10 skills, 2 commands |
| VSCode | `vscode-templates/{tasks,launch}.json` at `/opt/embedded/vscode-templates/` |
| Runner | `/opt/embedded/run-profile-task.sh` |

**No compiler.** That is intentional and correct — it keeps the shared layer
architecture-neutral and lets `arm` and `wch` share one cache of ~1.5 GB of
probe/analysis tooling.

### 5. ⚠ Verified defect: this image cannot currently build

I checked every `pacman` and AUR package name against the live Arch and AUR
package databases (2026-09-02). **Seven names do not resolve**, and `pacman -S`
aborts the whole transaction on the first unknown target, so the `RUN` layer
fails and no descendant image can build either.

#### Official-repo names that do not exist

| Name in Dockerfile | Status | Fix |
| --- | --- | --- |
| `gdb-multiarch` | **Not in Arch** (that is the Debian name) | Use **`gdb`**. Arch's `gdb` has been built with `--enable-targets=all --enable-multilib` since June 2024, so it *is* the multiarch GDB. |
| `clang-tools-extra` | **Not in Arch** | **Delete the line.** Arch's `clang` package already ships `clangd`, `clang-tidy`, `clang-format`, `clang-query`, `run-clang-tidy`. |
| `python-pyocd` | **AUR only** | Prefer `uv tool install pyocd` (this image already has `uv`), or install from AUR. |
| `tio` | **AUR only** | Install from AUR, or drop it — `picocom`, `minicom`, `screen` are all present already. |

#### AUR names that do not exist

| Name in Dockerfile | Status | Fix |
| --- | --- | --- |
| `probe-rs-bin` | **Not in AUR** | **`probe-rs` is now in Arch `extra` (0.32.0).** Move it to the `pacman` list and drop the AUR round-trip entirely. |
| `blackmagic` | **Not in AUR** | Drop it. BMP needs no host package — it exposes a GDB server directly on `/dev/ttyACM0`. Only `blackmagic-raw-sdk` exists in AUR and it is an unrelated Blackmagic Design product. |
| `wlink-bin` | **Not in AUR** | AUR has **`wlink`** (0.1.2), a from-source cargo build. It is WCH-only — move it to the `wch` leaf rather than paying for it in the shared base. |
| `picotool` | In AUR ✓ | Works, but builds from source against pico-sdk — slow. RP2040-only; consider moving to a leaf. |
| `paru-bin` | In AUR ✓ | Currently flagged out-of-date upstream. |

#### Suggested corrected package block

```dockerfile
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        gdb \
        openocd \
        stlink \
        probe-rs \
        clang lld llvm cppcheck \
        cmake ninja make dtc jq \
        picocom screen minicom \
        usbutils libusb libusb-compat hidapi \
        dfu-util \
        fakeroot patch \
    && pacman -Scc --noconfirm

# pyocd from PyPI — brings CMSIS-Pack support with it
RUN uv tool install pyocd --with cmsis-pack-manager
```

After that, the only remaining AUR need in this image is `tio` (optional) — which
means the entire `paru-bin` bootstrap (a full `makepkg` cycle, several minutes of
CI time) can be deleted from the base and pushed down to whichever leaf still
needs it.

### 6. Other verified issues

| # | Severity | Finding |
| --- | --- | --- |
| B1 | **High** | Build-breaking package names — §5. |
| B2 | **High** | `settings.json` declares `fetch` as `npx -y @modelcontextprotocol/server-fetch`. **That npm package does not exist** (registry returns 404). The fetch MCP is Python-only: use `uvx mcp-server-fetch`. Same bug is copied into `arm` and `web`. |
| B3 | Medium | The `aurbuild` user and its NOPASSWD sudoers entry are **left in the final image**. A second passwordless-sudo account with a home directory full of build artefacts is dead weight and needless attack surface. Delete the user and `/etc/sudoers.d/aurbuild` at the end of the AUR stage. |
| B4 | Medium | `COPY udev-rules/ /etc/udev/rules.d/` puts the rules in the image, where they can never fire — udev does not run in a container. Harmless, but it invites the belief that they are active. Move them to `/opt/embedded/udev-rules/` and have `probe-troubleshoot` point at them. |
| B5 | Medium | `launch.json` references `${env:OPENOCD_INTERFACE}` / `${env:OPENOCD_TARGET}` / `${env:SVD_FILE}`, but those values live in `.mcu-profile.json`, and nothing ever exports them into the environment. **Cortex-Debug launches will fail** unless the user sets them by hand. Either have `run-profile-task.sh` emit a `.env` file that `launch.json` consumes via `"envFile"`, or generate `launch.json` from the profile in `/scaffold-mcu-project`. |
| B6 | Medium | `launch.json`'s RISC-V configuration hard-codes `/usr/bin/riscv-none-elf-gdb`, but the WCH leaf installs that toolchain from AUR under `/opt/riscv-none-elf-gcc/bin/`. Path is likely wrong. |
| B7 | Low | `run-profile-task.sh` does `exec bash -c "$CMD"` on a string from a workspace file. That is arbitrary code execution from repo content — acceptable given you already run `--dangerously-skip-permissions`, but worth a comment in the script so it is a decision rather than an accident. |
| B8 | Low | `run-profile-task.sh` does not validate `$1` is present; `run-profile-task.sh` with no argument fails on `set -u` with an opaque message. |
| B9 | Low | The `Debug` task's `problemMatcher.endsPattern` matches `Listening on port 3333`, but openocd prints `Info : Listening on port 3333 for gdb connections` **before** `Listening on port 4444`. Fine in practice; brittle if openocd's output order changes. |
| B10 | Low | No `.svd` files anywhere in the fleet, and `register-decode-svd` depends on one. See §7.4. |
| B11 | Info | Base `dev-up.sh` builds an image the README then says not to use. Consider dropping it or renaming to `test-base.sh`. |

### 7. Proposed features

Ordered by value for the "base must stay generic" goal.

#### 7.1 A real `dev-doctor` / CI smoke test — do this first

Nothing currently verifies that the image contains what it advertises. A ten-line
CI step asserting `command -v` for every advertised binary would have caught all
of §5 on the first push. Pair it with a `dev-doctor` command in the image that
runs the same assertions plus probe visibility and Claude auth checks.

#### 7.2 Profile → environment bridge (fixes B5)

Teach `run-profile-task.sh` a `--export` mode that writes every non-command key
of `.mcu-profile.json` to `.vscode/.profile.env`, and add `"envFile":
"${workspaceFolder}/.vscode/.profile.env"` to the launch configurations. This
makes Cortex-Debug actually work off the profile, which is the whole point of the
design.

#### 7.3 Extend the profile schema

Add and standardise:

```jsonc
{
  "chip":        "STM32WBA65RI",     // canonical part number — drives everything else
  "probe":       "stlink|cmsis-dap|bmp|xds110|wlink",
  "flashTool":   "openocd|probe-rs|pyocd|cubeprog",
  "svd":         "svd/STM32WBA65.svd",
  "rttChannel":  0,
  "postBuild":   ["size", "hex", "bin"],
  "sizeBudget":  { "flash": 2097152, "ram": 524288 }
}
```

Then `run-profile-task.sh size` can fail the build when a firmware exceeds the
declared budget — a genuinely useful guardrail for AI-driven development, where
the model does not otherwise notice a slow creep in binary size.

#### 7.4 Ship an SVD store

Bake `cmsis-svd/cmsis-svd-data` (or the leaner `modm-io/cmsis-svd-stm32`) at
`/opt/svd` and add a `svd-find <chip>` helper. This turns
`register-decode-svd`, the Peripheral Viewer, and any register-level reasoning
from "user must supply a file" into "works out of the box".
Note that `modm-io/cmsis-svd-stm32` currently covers `stm32wba5` but **not**
`stm32wba6` — see the ARM writeup for the WBA65 path.

#### 7.5 RTT / SEGGER-style logging as a first-class citizen

`probe-rs` has built-in RTT (`probe-rs attach --rtt`). Add `rtt` as a profile key
and a VSCode task. For AI-driven development this is the single highest-value
addition in this list: it gives Claude a **non-interactive, machine-readable
feedback channel from the running target**, closing the loop from "write code" to
"observe what the hardware actually did". Everything else in the fleet is
open-loop.

#### 7.6 Hardware-in-the-loop test task

Standardise a `test` profile key: flash, run, capture RTT/UART for N seconds,
assert on a pattern, exit non-zero on failure. Combined with 7.5, this lets Claude
iterate against real silicon unattended.

#### 7.7 A `hardfault-decode` skill

Given a fault dump (CFSR/HFSR/BFAR/MMFAR + stacked frame) plus the `.elf`,
symbolise the PC/LR and name the fault cause. The most common embedded debugging
task and the one where an LLM adds the most leverage. Complements the existing
`gdb-debug-session` skill.

#### 7.8 `compile_commands.json` guarantee

clangd is configured with `--compile-commands-dir=${workspaceFolder}/build`, but
nothing guarantees the file exists before the first build. Have the entrypoint
emit a minimal fallback `.clangd` with the target's `-mcpu`/`-mthumb` flags so
that IDE completion works on a fresh clone.

#### 7.9 `ceedling` / `unity` / `gtest` host-side unit testing

Add a host-native (x86) test path so pure-logic modules can be tested without
hardware. `cmake` presets: `host-test` (gcc + gtest) alongside `target` (cross).
Cheap to add, big win for AI-driven refactoring confidence.

#### 7.10 Consolidate the duplicated Telink assets

`udev-rules/`, `run-profile-task.sh`, `vscode-templates/` exist in both this repo
and `docker-dev-embedded-telink`. Extract to a git submodule or a tiny
`docker-dev-embedded-common` image whose only job is to be `COPY --from=`'d.

### 8. Claude assets in this image

**Commands (2)**

| Command | Function |
| --- | --- |
| `/scaffold-mcu-project <arm\|wch\|telink>` | Creates `.vscode/{tasks,launch}.json` from the baked templates, copies the leaf's `profile.json` to `.mcu-profile.json`, generates a `CMakeLists.txt` + toolchain file + `src/main.cpp` skeleton, prints next steps. |
| `/probe-detect` | Runs `lsusb` (filtered by probe VID), checks `/dev/bus/usb`, `/dev/serial/by-id`, `probe-rs list`, `st-info --probe`, `id`, `/dev/ttyACM*`, and two `openocd` adapter scans; reports what is visible and diagnoses permission problems. |

**Skills (10)** — all architecture-neutral, which is the right call for this layer:

`clock-tree-derive` · `cpp-embedded-conventions` · `cpp-template-bloat-audit` ·
`firmware-binary-diff` · `gdb-debug-session` · `interrupt-priority-audit` ·
`linker-script-audit` · `probe-troubleshoot` · `register-decode-svd` ·
`stack-usage-estimate`

Two of them are not fully generic despite living here: `cpp-template-bloat-audit`
and `firmware-binary-diff` hard-code `arm-none-eabi-nm`. Parameterise as
`${CROSS_PREFIX}nm` and export `CROSS_PREFIX` from each leaf.

### 9. CI

Standard build-and-push to GHCR with GHA cache, plus `repository_dispatch`
fan-out to the `arm` and `wch` leaves. Triggered by push to `main`, tags `v*`,
manual dispatch, or a `base-image-updated` event from the template.

---

## Status: implemented 2026-09-02

Everything proposed in section 7 is now in the repo, and every defect in
sections 5 and 6 is fixed. The analysis above is kept as the record of *why*.

| Item | Resolution |
| --- | --- |
| B1 — seven bad package names | `gdb` (not `gdb-multiarch`), `clang-tools-extra` dropped (clang already ships clangd/tidy/format), `probe-rs` from Arch `extra`, pyocd via `uv tool install`, `blackmagic`/`wlink-bin`/`tio` removed. **The whole `paru-bin` AUR bootstrap is gone** — nothing left in this image needs it. |
| B2 — non-existent `fetch` npm package | `uvx mcp-server-fetch`; asserted in `tests/smoke.sh` |
| B3 — `aurbuild` left in the image | no AUR stage at all now; the smoke test asserts the user is absent |
| B4 — inert udev rules in `/etc/udev` | moved to `/opt/embedded/udev-rules/`; the installer finds them either way |
| B5 — `launch.json` env never exported | `mcu --export` writes `.vscode/.profile.env`, consumed via `envFile`; the `Debug` task runs it automatically |
| B6 — hard-coded RISC-V gdb path | `${env:CROSS_GDB}`, derived from `CROSS_PREFIX` by `mcu --export` |
| B7 — undocumented code execution | explicit SECURITY NOTE in `run-profile-task.sh` |
| B8 — missing arg validation | `mcu` validates, and has `--help` / `--list` / `--schema` |
| B9 — brittle problemMatcher | widened to match openocd *and* probe-rs |
| B10 — no SVDs | `/opt/svd` plus `svd-find` (search, `--set`, `--pack` via CMSIS-Pack) |
| 7.1 — dev-doctor + CI | `dev-doctor-checks/30-embedded.sh`, `tests/smoke.sh` |
| 7.3 — extended profile schema | `profile.schema.json`; `chip`/`core`/`fpu`/`floatAbi`/`probe`/`flashTool`/`sizeBudget`/`postBuild`/`testPass` |
| 7.5 — RTT | `rtt` profile key plus a VSCode task |
| 7.6 — hardware-in-the-loop test | built-in `mcu test`: flash, capture, assert |
| 7.7 — hardfault-decode skill | `claude-embedded-base/skills/hardfault-decode.md` |
| 7.8 — clangd fallback | `mcu --export` writes a `.clangd` from the profile's core/FPU |
| 7.9 — host-side unit tests | `cmake/host-test.cmake`, GoogleTest + Catch2 + gcovr |
| 7.10 — duplicated Telink assets | `scripts/sync-shared-assets.sh` (`--check` in CI) rather than a seventh repo |
| skills hard-coding `arm-none-eabi-` | parameterised to `${CROSS_PREFIX}` |

Also added: `mcu size` with `sizeBudget` enforcement, `embedded-common.cmake`
(`embedded_hardening` / `embedded_artifacts` / `embedded_stack_usage` /
`find_cmsis_dsp`), and a `downstream-verified` dispatch back to the template.
