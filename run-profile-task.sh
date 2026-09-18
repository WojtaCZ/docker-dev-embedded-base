#!/usr/bin/env bash
# Reads a command key from .mcu-profile.json and executes it.
# Installed as /opt/embedded/run-profile-task.sh and aliased to `mcu`.
#
# Usage:
#   mcu <key>            run the command stored under <key>
#   mcu --list           list available keys and settings
#   mcu --export [file]  write scalar profile keys as KEY=value (default
#                        .vscode/.profile.env) so launch.json's `envFile` can
#                        pick up OPENOCD_TARGET / SVD_FILE / BMP_PORT etc.
#                        Also writes a .clangd fallback if none exists.
#   mcu --clangd         (re)write the .clangd fallback
#   mcu --print <key>    print the command without running it
#   mcu --schema         show the profile schema
#
# Built-in keys, used when the profile does not define them:
#   size      section sizes, enforced against .sizeBudget
#   test      flash + capture target output + assert on .testPass/.testFail
#
# SECURITY NOTE: command strings come from a file in the workspace and are
# executed with `bash -c`. That is arbitrary code execution from repo content.
# It is a deliberate choice — this container is meant to be driven by an agent
# running with --dangerously-skip-permissions, and the container boundary is
# the security envelope. Do not point this at an untrusted repository.

set -uo pipefail

PROFILE_FILE="${PROFILE_FILE:-.mcu-profile.json}"
SCHEMA_FILE="${SCHEMA_FILE:-/opt/embedded/profile.schema.json}"

# Keys whose values are commands rather than settings.
TASK_KEYS='["build","buildDebug","clean","flash","erase","reset","serial","debugServer","rtt","size","test","hostTest"]'

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_profile() {
    [ -f "$PROFILE_FILE" ] || die "$PROFILE_FILE not found in $(pwd).
       Run /scaffold-mcu-project <arm|wch|telink> <part> from Claude to set up the workspace."
    jq -e . "$PROFILE_FILE" >/dev/null 2>&1 || die "$PROFILE_FILE is not valid JSON."
}

get() {
    jq -r --arg k "$1" '.[$k] // empty' "$PROFILE_FILE"
}

# Scalar (non-command, non-underscore) keys, emitted as KEY=value.
scalar_env() {
    jq -r --argjson tasks "$TASK_KEYS" '
        to_entries
        | map(select(.key | startswith("_") | not))
        | map(select(.value | type == "string" or type == "number"))
        | map(select(.key as $k | $tasks | index($k) | not))
        | .[] | "\(.key)=\(.value)"
    ' "$PROFILE_FILE"
}

export_scalars() {
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        export "${line%%=*}"="${line#*=}"
    done < <(scalar_env)
}

cross() {
    # Echo the cross-prefixed tool if it exists, otherwise the bare one.
    local tool="$1"
    if [ -n "${CROSS_PREFIX:-}" ] && command -v "${CROSS_PREFIX}${tool}" >/dev/null 2>&1; then
        echo "${CROSS_PREFIX}${tool}"
    else
        echo "$tool"
    fi
}

# --------------------------------------------------------------------------
# Built-in: size, with budget enforcement.
#
# The guardrail that stops binary size creeping up unnoticed across many small
# unattended edits. Put it in "postBuild": ["size"] and every build checks it.
# --------------------------------------------------------------------------
builtin_size() {
    local elf size_bin size_out
    local flash_used ram_used budget_flash budget_ram
    local rc=0

    elf="$(get ELF)"
    [ -n "$elf" ] || elf="build/firmware.elf"
    [ -f "$elf" ] || die "$elf not found — build first (or set ELF in $PROFILE_FILE)."

    size_bin="$(cross size)"
    size_out="$("$size_bin" -A "$elf")" || die "$size_bin failed on $elf"
    echo "$size_out"
    echo

    section() {
        awk -v s="$1" '$1 == s { print $2; found=1 } END { if (!found) print 0 }' <<< "$size_out" | head -1
    }

    local text rodata data bss
    text="$(section .text)"
    rodata="$(section .rodata)"
    data="$(section .data)"
    bss="$(section .bss)"

    flash_used=$(( text + rodata + data ))
    ram_used=$(( data + bss ))

    printf 'flash (text+rodata+data) : %s bytes\n' "$flash_used"
    printf 'ram   (data+bss)         : %s bytes\n' "$ram_used"

    budget_flash="$(jq -r '.sizeBudget.flash // empty' "$PROFILE_FILE")"
    budget_ram="$(jq -r '.sizeBudget.ram // empty' "$PROFILE_FILE")"

    if [ -n "$budget_flash" ] && [ "$budget_flash" -gt 0 ] 2>/dev/null; then
        printf 'flash budget             : %s bytes (%d%% used)\n' \
            "$budget_flash" $(( flash_used * 100 / budget_flash ))
        if [ "$flash_used" -gt "$budget_flash" ]; then
            echo "FAIL: flash budget exceeded by $(( flash_used - budget_flash )) bytes" >&2
            rc=1
        fi
    fi

    if [ -n "$budget_ram" ] && [ "$budget_ram" -gt 0 ] 2>/dev/null; then
        printf 'ram budget               : %s bytes (%d%% used)\n' \
            "$budget_ram" $(( ram_used * 100 / budget_ram ))
        if [ "$ram_used" -gt "$budget_ram" ]; then
            echo "FAIL: ram budget exceeded by $(( ram_used - budget_ram )) bytes" >&2
            echo "      note: this excludes stack and heap — real headroom is smaller." >&2
            rc=1
        fi
    fi

    return "$rc"
}

# --------------------------------------------------------------------------
# Built-in: hardware-in-the-loop test.
#
# Flash, capture whatever the target emits (RTT if defined, else the serial
# console) for testTimeout seconds, then assert. This is what closes the loop
# so an agent can iterate against real silicon without a human watching.
# --------------------------------------------------------------------------
builtin_test() {
    local timeout pass fail capture stream_cmd rc=0

    timeout="$(jq -r '.testTimeout // 30' "$PROFILE_FILE")"
    pass="$(get testPass)"
    fail="$(get testFail)"

    [ -n "$pass$fail" ] || die "profile defines neither testPass nor testFail — nothing to assert."

    stream_cmd="$(get rtt)"
    [ -n "$stream_cmd" ] || stream_cmd="$(get serial)"
    [ -n "$stream_cmd" ] || die "profile defines neither rtt nor serial — nowhere to read target output from."

    echo "== flashing =="
    run_key flash || return $?

    capture="$(mktemp)"

    echo "== capturing target output for ${timeout}s =="
    timeout --foreground "$timeout" bash -c "$stream_cmd" 2>&1 | tee "$capture" || true

    echo
    echo "== asserting =="
    if [ -n "$fail" ] && grep -Eq -- "$fail" "$capture"; then
        echo "FAIL: output matched testFail /$fail/" >&2
        rc=1
    fi
    if [ -n "$pass" ]; then
        if grep -Eq -- "$pass" "$capture"; then
            echo "PASS: output matched testPass /$pass/"
        else
            echo "FAIL: output never matched testPass /$pass/" >&2
            rc=1
        fi
    fi

    rm -f "$capture"
    return "$rc"
}

# --------------------------------------------------------------------------
# clangd fallback.
#
# clangd is pointed at build/compile_commands.json, which does not exist until
# the first successful build. On a fresh clone that means no completion and a
# wall of bogus errors from the cross headers. A .clangd carrying the core
# flags makes the editor usable immediately, and is harmless afterwards —
# compile_commands.json takes precedence once it appears.
# --------------------------------------------------------------------------
write_clangd_fallback() {
    local force="${1:-}"
    local core fpu abi cxx sysroot f
    local -a flags

    if [ -f .clangd ] && [ "$force" != "force" ]; then
        return 0
    fi

    core="$(get core)"
    fpu="$(get fpu)"
    abi="$(get floatAbi)"
    [ -n "$abi" ] || abi="hard"
    [ -n "$core" ] || return 0

    cxx="${CROSS_PREFIX:-}g++"
    command -v "$cxx" >/dev/null 2>&1 || return 0

    case "${CROSS_PREFIX:-}" in
        arm-none-eabi-)
            flags=(--target=arm-none-eabi -mthumb "-mcpu=${core}")
            ;;
        riscv-none-elf-|riscv32-elf-)
            flags=(--target=riscv32-none-elf "-march=${core}")
            ;;
        *)
            flags=()
            ;;
    esac
    flags+=(-std=c++20 -ffreestanding)

    if [ -n "$fpu" ] && [ "$fpu" != "none" ]; then
        flags+=("-mfpu=${fpu}" "-mfloat-abi=${abi}")
    fi

    sysroot="$("$cxx" -print-sysroot 2>/dev/null)" || sysroot=""

    {
        echo "# Generated by \`mcu --export\`. Fallback only: once"
        echo "# build/compile_commands.json exists, clangd prefers that."
        echo "CompileFlags:"
        echo "  Add:"
        for f in "${flags[@]}"; do
            echo "    - $f"
        done
        if [ -n "$sysroot" ]; then
            echo "    - --sysroot=$sysroot"
        fi
        echo "  Remove:"
        echo "    # GCC-only flags clang rejects, otherwise every file reports"
        echo "    # 'unknown argument' once compile_commands.json is generated."
        echo "    - --specs=*"
        echo "    - -fno-threadsafe-statics"
        echo "    - -fstack-usage"
        echo "    - -mno-*"
        echo "Diagnostics:"
        echo "  UnusedIncludes: Strict"
    } > .clangd

    echo "wrote .clangd fallback for ${core}"
}

# --------------------------------------------------------------------------
run_key() {
    local key="$1" cmd rc

    cmd="$(get "$key")"

    if [ -z "$cmd" ]; then
        case "$key" in
            size)
                builtin_size
                return $?
                ;;
            test)
                builtin_test
                return $?
                ;;
            *)
                die "key '$key' not found in $PROFILE_FILE (try: mcu --list)"
                ;;
        esac
    fi

    # Scalars become environment variables so command strings can use $chip,
    # $ELF, $OPENOCD_TARGET and friends.
    export_scalars

    bash -c "$cmd"
    rc=$?
    return "$rc"
}

do_list() {
    echo "Tasks defined in $PROFILE_FILE:"
    jq -r --argjson tasks "$TASK_KEYS" '
        to_entries
        | map(select(.value | type == "string"))
        | map(select(.key as $k | $tasks | index($k)))
        | .[] | "  \(.key)"' "$PROFILE_FILE"
    echo
    echo "Built-ins (available even when not defined above):"
    echo "  size    section sizes + sizeBudget enforcement"
    echo "  test    flash, capture target output, assert on testPass/testFail"
    echo
    echo "Settings (exported to the environment, and to .vscode/.profile.env):"
    scalar_env | sed 's/^/  /'
    local pb
    pb="$(jq -r '.postBuild // [] | join(", ")' "$PROFILE_FILE")"
    if [ -n "$pb" ]; then
        echo
        echo "postBuild chain after a successful build: $pb"
    fi
}

do_export() {
    local out="$1"
    local gdb_path
    mkdir -p "$(dirname "$out")"
    scalar_env > "$out"

    # CROSS_GDB is derived rather than stored: launch.json needs an absolute
    # path and the prefix differs per leaf image.
    if [ -n "${CROSS_PREFIX:-}" ] && command -v "${CROSS_PREFIX}gdb" >/dev/null 2>&1; then
        gdb_path="$(command -v "${CROSS_PREFIX}gdb")"
        echo "CROSS_GDB=${gdb_path}" >> "$out"
    fi

    echo "wrote $(wc -l < "$out") settings to $out"
    write_clangd_fallback
}

main() {
    local key rc extra

    [ $# -ge 1 ] || die "no key given. Usage: mcu <key> | mcu --list | mcu --export | mcu --schema"

    case "$1" in
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            return 0
            ;;
        --schema)
            [ -f "$SCHEMA_FILE" ] || die "$SCHEMA_FILE not found"
            cat "$SCHEMA_FILE"
            return 0
            ;;
        --list)
            require_profile
            do_list
            return 0
            ;;
        --export)
            require_profile
            do_export "${2:-.vscode/.profile.env}"
            return 0
            ;;
        --clangd)
            require_profile
            write_clangd_fallback force
            return 0
            ;;
        --print)
            require_profile
            [ $# -ge 2 ] || die "--print needs a key"
            get "$2"
            return 0
            ;;
        -*)
            die "unknown option '$1' (try: mcu --help)"
            ;;
    esac

    require_profile
    key="$1"

    run_key "$key"
    rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    # postBuild chain — only after a successful `build`.
    if [ "$key" = "build" ]; then
        while IFS= read -r extra; do
            [ -n "$extra" ] || continue
            echo "== postBuild: $extra =="
            run_key "$extra"
            rc=$?
            [ "$rc" -eq 0 ] || return "$rc"
        done < <(jq -r '.postBuild // [] | .[]' "$PROFILE_FILE")
    fi

    return 0
}

main "$@"
