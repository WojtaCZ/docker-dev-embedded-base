# syntax=docker/dockerfile:1.7
FROM ghcr.io/wojtacz/docker-dev-template:latest

USER root

# Embedded tooling: probe drivers, debug tools, C++ analysis, build system, serial console, USB
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        gdb-multiarch \
        openocd \
        stlink \
        python-pyocd \
        clang \
        lld \
        llvm \
        clang-tools-extra \
        cppcheck \
        cmake \
        ninja \
        make \
        dtc \
        jq \
        picocom \
        tio \
        screen \
        minicom \
        usbutils \
        libusb \
        libusb-compat \
        hidapi \
        fakeroot \
        patch \
    && pacman -Scc --noconfirm

# AUR helper (paru-bin) for probe-rs, blackmagic, picotool, wlink-bin
RUN useradd -m aurbuild && echo "aurbuild ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/aurbuild
USER aurbuild
RUN cd /tmp && \
    git clone https://aur.archlinux.org/paru-bin.git && \
    cd paru-bin && makepkg -si --noconfirm && \
    rm -rf /tmp/paru-bin
USER root

# Probe CLI tools (work against any target architecture in any leaf)
RUN su aurbuild -c "paru -S --noconfirm --needed \
        blackmagic \
        probe-rs \
        picotool \
        wlink-bin"

# udev rules for all supported probes (also install on the host — see scripts/install-host-udev-rules.sh)
COPY udev-rules/ /etc/udev/rules.d/

# Group membership so /dev/ttyACM* and probe nodes are accessible
RUN groupadd -f plugdev && \
    usermod -aG dialout,uucp,tty,plugdev,lock dev

# Profile task runner and VSCode templates
COPY run-profile-task.sh /opt/embedded/run-profile-task.sh
RUN chmod +x /opt/embedded/run-profile-task.sh
COPY vscode-templates/ /opt/embedded/vscode-templates/

USER dev

# Stack embedded-specific Claude config on top of the baseline baked by the parent image.
# settings.json replaces the baseline — it re-declares all baseline MCPs plus embedded additions.
COPY --chown=dev:dev claude-embedded-base/skills/      /home/dev/.claude/skills/
COPY --chown=dev:dev claude-embedded-base/commands/    /home/dev/.claude/commands/
COPY --chown=dev:dev claude-embedded-base/agents/      /home/dev/.claude/agents/
COPY --chown=dev:dev claude-embedded-base/settings.json /home/dev/.claude/settings.json

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
