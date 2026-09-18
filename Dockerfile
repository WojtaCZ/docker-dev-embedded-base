# syntax=docker/dockerfile:1.7
ARG BASE_TAG=latest
FROM ghcr.io/wojtacz/docker-dev-template:${BASE_TAG}

USER root

# Pinned upstream revisions. Bumping one shows up in the diff instead of
# silently changing what the image contains between two builds of the same tag.
ARG CMSIS_SVD_REF=main

# ---------------------------------------------------------------------------
# Rebuild the pacman trust database.
#
# The inherited image ships /etc/pacman.d/gnupg WITHOUT a local signing key,
# so every Arch developer key sits at [marginal] trust and any package they
# sign is rejected with "invalid or corrupted package (PGP signature)" — even
# though archlinux-keyring itself is current. pacman-key --populate cannot
# repair it on its own; it fails with "no secret key available to sign with".
# --init regenerates that key, after which --populate locally signs the master
# keys and the developer keys resolve to [full].
# ---------------------------------------------------------------------------
RUN pacman-key --init && \
    pacman-key --populate archlinux

# ---------------------------------------------------------------------------
# Embedded tooling: probe drivers, debug tools, C++ analysis, build systems,
# serial console, USB, host-side unit testing.
#
# Arch package-name notes (all verified against the official repos):
#   * `gdb`  — NOT `gdb-multiarch`. That is the Debian name; Arch's gdb is built
#     with --enable-targets=all --enable-multilib, so it IS the multiarch gdb.
#   * `clang` already ships clangd / clang-tidy / clang-format / clang-query.
#     There is no separate `clang-tools-extra` package.
#   * `probe-rs` is in `extra` as of 0.32 — no AUR round-trip needed.
#   * pyocd and tio are NOT in the official repos; see below.
# ---------------------------------------------------------------------------
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        gdb \
        openocd \
        stlink \
        probe-rs \
        dfu-util \
        clang \
        lld \
        llvm \
        cppcheck \
        cmake \
        ninja \
        make \
        meson \
        ccache \
        dtc \
        jq \
        picocom \
        screen \
        minicom \
        socat \
        usbutils \
        libusb \
        libusb-compat \
        hidapi \
        python-pyelftools \
        python-pyserial \
        gtest \
        catch2 \
        gcovr \
        lcov \
        rsync \
        fakeroot \
        patch \
    && pacman -Scc --noconfirm

# pyOCD from PyPI (it is not in the Arch repos). Brings cmsis-pack-manager with
# it, which is how you get device support and SVDs for parts newer than the
# current OpenOCD release:
#     pyocd pack find stm32wba
#     pyocd pack install stm32wba65ri
# UV_TOOL_BIN_DIR puts the launcher somewhere every user can reach, rather than
# in root's ~/.local/bin where `dev` would never see it.
ENV UV_TOOL_DIR=/opt/uv-tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    PYOCD_HOME=/opt/pyocd
RUN uv tool install pyocd && \
    mkdir -p /opt/pyocd && chmod 0777 /opt/pyocd && \
    pyocd --version

# NOTE: no AUR helper in this image. Everything here now has an official Arch
# package, so the paru-bin bootstrap (a full makepkg cycle on every CI build)
# was removed. `tio` is the only casualty — picocom, minicom, screen and socat
# cover the same ground. Leaves that genuinely need AUR (wch) bootstrap their
# own helper.

# ---------------------------------------------------------------------------
# SVD store. Register-level reasoning, the VSCode Peripheral Viewer and the
# register-decode-svd skill all need a .svd for the target; shipping a store
# turns "user must supply a file" into "works out of the box".
#
# This is the multi-vendor set (Atmel, Espressif, Nordic, NXP, SiFive, TI, ...).
# It is not exhaustive for recent STM32 parts — the arm leaf adds modm-io's
# STM32-specific mirror on top, and `svd-find` searches both.
# ---------------------------------------------------------------------------
RUN git clone --depth=1 --branch "${CMSIS_SVD_REF}" \
        https://github.com/cmsis-svd/cmsis-svd-data /opt/svd/cmsis-svd-data && \
    rm -rf /opt/svd/cmsis-svd-data/.git
ENV SVD_STORE=/opt/svd

# ---------------------------------------------------------------------------
# udev rules.
# udev does NOT run inside a container, so these are inert here — they are
# shipped so `install-host-udev-rules.sh` can install them on the HOST. They
# live under /opt/embedded so nobody mistakes them for active rules.
# ---------------------------------------------------------------------------
COPY udev-rules/ /opt/embedded/udev-rules/

# Group membership so /dev/ttyACM* and probe nodes are accessible
RUN groupadd -f plugdev && \
    groupadd -f dialout && \
    usermod -aG dialout,uucp,tty,plugdev,lock dev

# Profile task runner, helpers and VSCode templates
COPY run-profile-task.sh          /opt/embedded/run-profile-task.sh
COPY scripts/svd-find.sh          /opt/embedded/svd-find
COPY scripts/install-host-udev-rules.sh /opt/embedded/install-host-udev-rules.sh
COPY profile.schema.json          /opt/embedded/profile.schema.json
RUN chmod +x /opt/embedded/run-profile-task.sh \
             /opt/embedded/svd-find \
             /opt/embedded/install-host-udev-rules.sh && \
    ln -sf /opt/embedded/run-profile-task.sh /usr/local/bin/mcu && \
    ln -sf /opt/embedded/svd-find            /usr/local/bin/svd-find
COPY vscode-templates/ /opt/embedded/vscode-templates/
COPY cmake/            /opt/embedded/cmake/

# dev-doctor checks contributed by this layer
COPY dev-doctor-checks/ /opt/dev-doctor/checks.d/
RUN chmod +x /opt/dev-doctor/checks.d/*.sh

USER dev

# Stack embedded-specific Claude config on top of the baseline baked by the
# parent image. skills/, commands/ and agents/ merge additively; settings are
# contributed as a numbered layer that the entrypoint merges, so this file
# declares only what embedded-base ADDS.
COPY --chown=dev:dev claude-embedded-base/skills/   /home/dev/.claude/skills/
COPY --chown=dev:dev claude-embedded-base/commands/ /home/dev/.claude/commands/
COPY --chown=dev:dev claude-embedded-base/agents/   /home/dev/.claude/agents/
COPY --chown=dev:dev claude-embedded-base/settings.layer.json \
     /home/dev/.claude-layers/10-embedded.json

# Memory layer: the embedded tool inventory, concatenated into ~/.claude/CLAUDE.md
# by entrypoint.sh so the in-container Claude knows what it has without searching.
COPY --chown=dev:dev claude-embedded-base/CLAUDE.layer.md \
     /home/dev/.claude-memory-layers/10-embedded.md

# Cross-toolchain prefix. Leaves override it (arm → arm-none-eabi-,
# wch → riscv-none-elf-) so the shared binutils-driven skills work everywhere.
ENV CROSS_PREFIX=""

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
