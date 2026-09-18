#!/usr/bin/env bash
# Smoke test for docker-dev-embedded-base. Runs INSIDE the built image.
#
#   docker run --rm -e DEV_SKIP_UPDATE=1 -v "$PWD/tests:/tests:ro" <image> bash /tests/smoke.sh
#
# Leaf images source this and then add their own checks, so keep everything
# here architecture-neutral.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

echo "== probe / flash / debug tooling =="
for b in openocd probe-rs pyocd st-info gdb dfu-util; do
    command -v "$b" >/dev/null || fail "missing: $b"
    pass "$b"
done

echo "== build + analysis =="
for b in cmake ninja make meson ccache clang clangd clang-tidy clang-format cppcheck gcovr; do
    command -v "$b" >/dev/null || fail "missing: $b"
    pass "$b"
done

echo "== serial =="
for b in picocom minicom screen socat; do
    command -v "$b" >/dev/null || fail "missing: $b"
    pass "$b"
done

echo "== fleet helpers =="
for b in mcu svd-find dev-doctor; do
    command -v "$b" >/dev/null || fail "missing: $b"
    pass "$b"
done

echo "== gdb is genuinely multiarch =="
# Arch's `gdb` is built --enable-targets=all, which is why the fleet does not
# need Debian's `gdb-multiarch` (a package that does not exist on Arch).
gdb --batch -ex 'set architecture arm'   >/dev/null 2>&1 || fail "gdb rejects arm"
gdb --batch -ex 'set architecture riscv' >/dev/null 2>&1 || fail "gdb rejects riscv"
pass "gdb accepts arm and riscv"

echo "== no AUR helper left behind =="
! id aurbuild >/dev/null 2>&1 || fail "aurbuild user still present in the shipped image"
[ ! -f /etc/sudoers.d/aurbuild ] || fail "/etc/sudoers.d/aurbuild still present"
pass "no leftover build user"

echo "== settings layers merged =="
S="$HOME/.claude/settings.json"
[ -s "$S" ] || fail "entrypoint did not produce $S"
for server in github git context7 sequential-thinking fetch; do
    jq -e --arg s "$server" '.mcpServers | has($s)' "$S" >/dev/null \
        || fail "MCP server '$server' missing from merged settings"
    pass "mcp: $server"
done
# The fetch MCP must be the Python one — @modelcontextprotocol/server-fetch
# does not exist on npm, so an npx-based declaration silently never starts.
[ "$(jq -r '.mcpServers.fetch.command' "$S")" = "uvx" ] \
    || fail "fetch MCP must use uvx (the npm package does not exist)"
pass "fetch MCP uses uvx"

while IFS=$'\t' read -r name cmd; do
    [ -n "$name" ] || continue
    command -v "$cmd" >/dev/null || fail "MCP '$name' needs '$cmd', not on PATH"
done < <(jq -r '.mcpServers // {} | to_entries[] | "\(.key)\t\(.value.command)"' "$S")
pass "every MCP launcher resolves"

echo "== claude assets =="
for f in probe-detect scaffold-mcu-project; do
    [ -f "$HOME/.claude/commands/$f.md" ] || fail "command $f.md not installed"
    pass "command: /$f"
done
n_skills=$(find "$HOME/.claude/skills" -name '*.md' | wc -l)
[ "$n_skills" -ge 11 ] || fail "expected >=11 skills, found $n_skills"
pass "$n_skills skills installed"

echo "== SVD store =="
n_svd=$(find "${SVD_STORE:-/opt/svd}" -name '*.svd' 2>/dev/null | wc -l)
[ "$n_svd" -gt 100 ] || fail "SVD store looks empty ($n_svd files)"
pass "$n_svd SVD files under ${SVD_STORE:-/opt/svd}"
svd-find stm32f4 | head -3
pass "svd-find returns matches"

echo "== vscode templates + cmake helpers =="
for f in /opt/embedded/vscode-templates/tasks.json \
         /opt/embedded/vscode-templates/launch.json \
         /opt/embedded/profile.schema.json \
         /opt/embedded/cmake/embedded-common.cmake \
         /opt/embedded/cmake/host-test.cmake; do
    [ -f "$f" ] || fail "missing $f"
    case "$f" in *.json) jq -e . "$f" >/dev/null || fail "$f is not valid JSON";; esac
    pass "$(basename "$f")"
done

echo "== udev rules shipped for host install =="
n_rules=$(find /opt/embedded/udev-rules -name '*.rules' | wc -l)
[ "$n_rules" -ge 7 ] || fail "expected >=7 udev rule files, found $n_rules"
[ ! -d /etc/udev/rules.d ] || [ -z "$(ls -A /etc/udev/rules.d 2>/dev/null)" ] \
    || echo "  note: /etc/udev/rules.d is non-empty; rules there are inert in a container"
pass "$n_rules udev rule files under /opt/embedded/udev-rules"

echo "== profile runner, end to end =="
work=$(mktemp -d)
cd "$work"
python - <<'PY'
import json
json.dump({
    "chip": "STM32F407VG",
    "core": "cortex-m4",
    "fpu": "fpv4-sp-d16",
    "floatAbi": "hard",
    "OPENOCD_TARGET": "target/stm32f4x.cfg",
    "ELF": "build/firmware.elf",
    "build": "echo BUILD_OK",
    "clean": "echo CLEAN_OK",
    "flash": "echo FLASH_OK $chip",
    "postBuild": ["clean"],
}, open(".mcu-profile.json", "w"), indent=2)
PY

mcu --schema | jq -e '.title' >/dev/null || fail "mcu --schema broken"
pass "mcu --schema"

# Captured, not piped: `mcu --list` writes its sections in several writes and
# `grep -q` exits on the first match, so under `set -o pipefail` the pipeline
# reports mcu's SIGPIPE (141) instead of grep's match.
listing=$(mcu --list)
grep -q 'build' <<< "$listing"            || fail "mcu --list did not show tasks"
grep -q 'chip=STM32F407VG' <<< "$listing" || fail "mcu --list did not show settings"
pass "mcu --list"

mcu --print build | grep -q BUILD_OK || fail "mcu --print broken"
pass "mcu --print"

out=$(mcu build)
grep -q BUILD_OK <<< "$out" || fail "mcu build did not run the build command"
grep -q CLEAN_OK <<< "$out" || fail "postBuild chain did not run"
pass "mcu build + postBuild chain"

# Scalars must reach the command as environment variables.
mcu flash | grep -q 'FLASH_OK STM32F407VG' || fail "scalar keys not exported to commands"
pass "scalars exported into task commands"

mcu --export ./env.out >/dev/null
grep -q 'OPENOCD_TARGET=target/stm32f4x.cfg' ./env.out || fail "mcu --export missing key"
! grep -q '^build=' ./env.out || fail "mcu --export leaked a task command into the env file"
pass "mcu --export writes settings only"

if ! mcu nosuchkey >/dev/null 2>&1; then
    pass "unknown key fails loudly"
else
    fail "unknown key should exit non-zero"
fi

# Size budget enforcement, using a host ELF so no cross toolchain is needed.
echo 'int main(void){return 0;}' > t.c
cc -o build_elf t.c
python - <<'PY'
import json
p = json.load(open(".mcu-profile.json"))
p["ELF"] = "build_elf"
p["sizeBudget"] = {"flash": 1, "ram": 1}      # deliberately impossible
json.dump(p, open(".mcu-profile.json", "w"), indent=2)
PY
if mcu size >/dev/null 2>&1; then
    fail "mcu size should have failed against a 1-byte budget"
fi
pass "size budget is enforced"

python - <<'PY'
import json
p = json.load(open(".mcu-profile.json"))
p["sizeBudget"] = {"flash": 100000000, "ram": 100000000}
json.dump(p, open(".mcu-profile.json", "w"), indent=2)
PY
mcu size >/dev/null || fail "mcu size failed against a generous budget"
pass "size passes within budget"

cd /
rm -rf "$work"

echo "== host unit test harness =="
ht=$(mktemp -d)
mkdir -p "$ht/test/host"
cat > "$ht/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(ht CXX)
include(/opt/embedded/cmake/host-test.cmake)
add_host_test_suite(demo SOURCES test/host/t.cpp)
CMAKE
cat > "$ht/test/host/t.cpp" <<'CPP'
#include <gtest/gtest.h>
TEST(Demo, Adds) { EXPECT_EQ(2 + 2, 4); }
CPP
cmake -S "$ht" -B "$ht/b" -G Ninja >/dev/null
cmake --build "$ht/b" >/dev/null
ctest --test-dir "$ht/b" --output-on-failure
rm -rf "$ht"
pass "host test harness builds and runs"

echo "== dev-doctor =="
dev-doctor
dev-doctor --json | jq -e '.ok == true' >/dev/null || fail "dev-doctor reported failures"
pass "dev-doctor clean"

echo "== CLAUDE.md memory layers assembled =="
M="$HOME/.claude/CLAUDE.md"
[ -d "$HOME/.claude-memory-layers" ] || fail "$HOME/.claude-memory-layers missing"
for l in 00-baseline.md 10-embedded.md; do
    [ -f "$HOME/.claude-memory-layers/$l" ] || fail "memory layer $l not installed"
done
pass "memory layers present: $(ls "$HOME/.claude-memory-layers" | tr '\n' ' ')"
[ -s "$M" ] || fail "entrypoint did not assemble ~/.claude/CLAUDE.md"
grep -q "## Embedded layer" "$M" || fail "merged CLAUDE.md is missing this image's layer (## Embedded layer)"
pass "CLAUDE.md assembled, this image's layer present"

echo
echo "SMOKE TEST PASSED"
