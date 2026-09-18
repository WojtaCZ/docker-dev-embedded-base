#!/usr/bin/env bash
# dev-doctor checks contributed by docker-dev-embedded-base.
# Emits STATUS|name|detail lines. STATUS in OK / WARN / FAIL.

set -uo pipefail

emit() { echo "$1|$2|$3"; }
have() { command -v "$1" >/dev/null 2>&1; }

need() {
    local bin="$1" label="${2:-$1}"
    if have "$bin"; then
        emit OK "$label" "$(command -v "$bin")"
    else
        emit FAIL "$label" "not found on PATH"
    fi
}

# Probe / flash / debug tooling
for b in openocd probe-rs pyocd st-info gdb dfu-util; do
    need "$b"
done

# Build + analysis
for b in cmake ninja make clang clangd clang-tidy clang-format cppcheck; do
    need "$b"
done

# Serial
for b in picocom minicom screen socat; do
    need "$b"
done

# Versions worth knowing at a glance
have openocd  && emit OK "openocd-version"  "$(openocd --version 2>&1 | head -1)"
have probe-rs && emit OK "probe-rs-version" "$(probe-rs --version 2>&1 | head -1)"
have gdb      && emit OK "gdb-version"      "$(gdb --version 2>&1 | head -1)"

# gdb must actually be multiarch, otherwise cross debugging silently fails
if have gdb; then
    if gdb --batch -ex 'set architecture arm' >/dev/null 2>&1; then
        emit OK "gdb-multiarch" "arm architecture accepted"
    else
        emit FAIL "gdb-multiarch" "gdb rejects 'set architecture arm' — not built --enable-targets=all"
    fi
fi

# Profile runner
if [ -x /opt/embedded/run-profile-task.sh ]; then
    emit OK "mcu-runner" "/opt/embedded/run-profile-task.sh"
else
    emit FAIL "mcu-runner" "profile task runner missing or not executable"
fi
have mcu && emit OK "mcu-alias" "$(command -v mcu)"

# VSCode templates
for f in tasks.json launch.json; do
    if [ -f "/opt/embedded/vscode-templates/$f" ]; then
        emit OK "vscode-$f" "present"
    else
        emit FAIL "vscode-$f" "missing from /opt/embedded/vscode-templates"
    fi
done

# SVD store
SVD_STORE="${SVD_STORE:-/opt/svd}"
if [ -d "$SVD_STORE" ]; then
    n="$(find "$SVD_STORE" -maxdepth 4 -type f -iname '*.svd' 2>/dev/null | wc -l)"
    if [ "$n" -gt 0 ]; then
        emit OK "svd-store" "$n SVD file(s) under $SVD_STORE"
    else
        emit WARN "svd-store" "$SVD_STORE exists but holds no .svd files"
    fi
else
    emit WARN "svd-store" "$SVD_STORE not present"
fi
have svd-find && emit OK "svd-find" "$(command -v svd-find)"

# USB / probe visibility. Absent USB is normal in CI, so warn rather than fail.
if [ -d /dev/bus/usb ]; then
    emit OK "usb-passthrough" "/dev/bus/usb mounted"
    if have lsusb; then
        n="$(lsusb 2>/dev/null | grep -icE 'stlink|blackmagic|cmsis|1d50|0483|1a86|0451|2e8a|1366|0d28' || true)"
        if [ "${n:-0}" -gt 0 ]; then
            emit OK "probe-visible" "$n probe-like USB device(s)"
        else
            emit WARN "probe-visible" "no debug probe seen on USB"
        fi
    fi
else
    emit WARN "usb-passthrough" "/dev/bus/usb not mounted — run dev-up.sh with the probe already plugged in"
fi

# Serial device group membership
if id -nG | grep -qw dialout; then
    emit OK "groups" "in dialout: $(id -nG)"
else
    emit WARN "groups" "not in dialout — /dev/ttyACM* may be unreadable"
fi

# Host-side unit test libraries
for pc in gtest catch2-with-main; do
    if pkg-config --exists "$pc" 2>/dev/null; then
        emit OK "hosttest:$pc" "$(pkg-config --modversion "$pc" 2>/dev/null)"
    else
        emit WARN "hosttest:$pc" "pkg-config cannot find $pc"
    fi
done

# Cross toolchain, if a leaf declared one
if [ -n "${CROSS_PREFIX:-}" ]; then
    for t in gcc g++ objdump nm size; do
        if have "${CROSS_PREFIX}${t}"; then
            emit OK "cross:${CROSS_PREFIX}${t}" "$(command -v "${CROSS_PREFIX}${t}")"
        else
            emit FAIL "cross:${CROSS_PREFIX}${t}" "declared CROSS_PREFIX but binary missing"
        fi
    done
else
    emit OK "cross-prefix" "unset (expected in embedded-base — leaves set it)"
fi
