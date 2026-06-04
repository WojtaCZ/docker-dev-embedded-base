# docker-dev-embedded-base

Shared foundation for all embedded development containers. Inherits from
[docker-dev-template](https://github.com/wojtacz/docker-dev-template) and adds
every probe driver, debug tool, and C++ analysis utility that is useful across
all target architectures. Compiler toolchains live in the per-architecture leaf
images — this image has none.

## Repository hierarchy

```
docker-dev-template            (Arch Linux + Claude Code)
  └── docker-dev-embedded-base (this image — probe tools, skills, VSCode templates)
       ├── docker-dev-embedded-arm     (arm-none-eabi-g++, CMSIS, CMSIS-DSP)
       └── docker-dev-embedded-wch     (riscv-none-elf-g++, ch32v003fun)

docker-dev-template
  └── docker-dev-embedded-telink  (tc32 toolchain via host-mounted SDK)
```

Use a leaf image directly — this base image is not meant to be used on its own
for firmware development.

## What's in this image

- **Debug probes:** openocd, stlink, pyocd, Black Magic Probe CLI, probe-rs, picotool, wlink
- **GDB:** gdb-multiarch (ARM, RISC-V, and beyond)
- **C++ analysis:** clangd, clang-format, clang-tidy, cppcheck
- **Build:** cmake, ninja, make
- **Serial console:** picocom, tio, screen, minicom
- **Claude Code** with 10 embedded-specific skills and 2 commands

## One-time host setup (run once per Linux host)

```bash
# Install udev rules so probe device nodes have the right group ownership
sudo ./scripts/install-host-udev-rules.sh

# Add yourself to dialout and plugdev (log out/in after)
sudo usermod -aG dialout,plugdev $USER
```

> **Note:** udev does not run inside Docker containers. The udev rules in this
> repo must also be installed on the host so that `/dev/bus/usb` node ownership
> is correct when bind-mounted into the container.

## Usage (as a developer using a leaf image)

Use the leaf image's `dev-up.sh`. This base image's `dev-up.sh` is provided
for testing the base layer only.

```bash
# Build and start (pulls latest base layer by default)
./scripts/dev-up.sh

# Mount a specific project directory
./scripts/dev-up.sh /path/to/firmware

# Offline / pinned — don't pull base image
DEV_NO_PULL=1 ./scripts/dev-up.sh

# Pass through a specific probe TTY (BMP second serial port)
DEV_PROBE=/dev/ttyACM1 ./scripts/dev-up.sh
```

## Template update propagation

This image tracks `ghcr.io/wojtacz/docker-dev-template:latest` via a floating
`FROM` tag. On every `dev-up.sh` run the `--pull` flag causes Docker to check
for a fresher base layer.

CI additionally: when `docker-dev-template` pushes to `main` it fires a
`repository_dispatch` event here, which triggers a rebuild and republish of
this image. That republish in turn dispatches to the `arm` and `wch` leaves.

### Setting up the dispatch PAT

1. Create a fine-grained PAT with `Contents: Read and Write` on
   `docker-dev-embedded-arm` and `docker-dev-embedded-wch`.
2. Add it as `DOWNSTREAM_DISPATCH_PAT` secret on this repo.
3. Add the same PAT as `DOWNSTREAM_DISPATCH_PAT` on `docker-dev-template`
   (targeting this repo and `docker-dev-embedded-telink`).

## VSCode task template

The shared `vscode-templates/tasks.json` and `launch.json` are baked into the
image at `/opt/embedded/vscode-templates/`. Leaf images ship a default
`profile.json` at `/opt/embedded/profile.json`. The `/scaffold-mcu-project`
Claude command copies both into the workspace and generates a CMakeLists.txt
skeleton.

Task execution goes through `/opt/embedded/run-profile-task.sh` which reads
`.mcu-profile.json` from the workspace root — edit that file to customise
commands per project without touching `tasks.json`.
