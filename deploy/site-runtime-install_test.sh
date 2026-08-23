#!/usr/bin/env bash
# Offline test for deploy/site-runtime-install.sh — the site-plane installer.
#
# The installer is streamed to a box as ONE file (cp-ops scp's exactly
# deploy/site-runtime-install.sh), so it must stay self-contained: the systemd
# units live in the script as heredocs, NOT as repo files it reads at run time.
# That self-containment is what makes drift possible, so the units are ALSO
# staged as canonical files under deploy/systemd/ and this test byte-diffs the
# two — edit one side only and the gate goes red.
#
# Proves:
#   - unit parity: each heredoc in the script is byte-identical to its staged
#     deploy/systemd/<unit>.service, and neither side is empty
#   - the builder unit keeps its __PLATFORM__ / __BUILDER_TOKEN__ placeholders
#     on BOTH sides, and the script's sed fills both in (no `__` left over)
#   - the runtime unit carries no placeholder (fixed agent-token identity)
#   - arch: the Go toolchain branch resolves x86_64 -> linux-amd64 and
#     aarch64 -> linux-arm64 (it used to hardcode arm64, which aborted a bare
#     default cx23 x86 box under `set -euo pipefail`), an unknown arch fails
#     loudly with exit 1, and the tarball URL is built from that branch
#   - git is never assumed: it installs beside docker on a bare box, is probed
#     independently when docker already existed, and the probe header prints
#     `git --version` — the git-ref clone lane makes git load-bearing at BUILD
#     time, not just at checkout time
#
# Replays are BEHAVIOURAL: the script's own marked blocks are extracted and run
# in a clean shell against fake uname/apt-get/curl/tar on a fake-only PATH, so a
# rename or a reordering inside those blocks is caught, not just a grep string.
# Never touches a server: no root, no network, no systemctl.
# Run: bash deploy/site-runtime-install_test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/site-runtime-install.sh"
STAGED="$HERE/systemd"
TMP="$(mktemp -d)"
BASH_BIN="$(command -v bash)"   # the replays run on a fake-only PATH
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

# --- extraction -------------------------------------------------------------

# Body of `cat > /etc/systemd/system/<unit> <<'UNIT' ... UNIT`, exactly as the
# box would receive it (quoted heredoc: no expansion, so this IS the bytes).
extract_unit() {
  awk -v start="cat > /etc/systemd/system/$1 <<'UNIT'" '
    $0 == start { in_block = 1; next }
    in_block && $0 == "UNIT" { exit }
    in_block { print }
  ' "$SCRIPT"
}

# A `# <name> (start)` … `# <name> (end)` block of the script, for replay.
extract_block() {
  awk -v s="# $1 (start)" -v e="# $1 (end)" '
    $0 == s { in_block = 1; next }
    $0 == e { exit }
    in_block { print }
  ' "$SCRIPT"
}

# --- fakes ------------------------------------------------------------------
# /bin/sh shebangs and builtin-only bodies: the replays run with PATH set to the
# fake dir ALONE, which is the only honest way to test "git is not installed".

make_fakes() {
  local dir="$1" arch="${2:-x86_64}"; mkdir -p "$dir"
  cat > "$dir/uname" <<EOF
#!/bin/sh
echo "$arch"
EOF
  cat > "$dir/apt-get" <<EOF
#!/bin/sh
echo "apt-get \$*" >> "$dir/apt.log"
# an install that names git actually yields a usable git, like the real one
for a in "\$@"; do
  if [ "\$a" = "git" ]; then
    printf '%s\n' '#!/bin/sh' 'echo "git version 2.39.0-fake"' > "$dir/git"
    /bin/chmod +x "$dir/git"   # absolute: the replay PATH holds only fakes
  fi
done
EOF
  cat > "$dir/curl" <<EOF
#!/bin/sh
# record the URL (last arg) instead of fetching it
for a in "\$@"; do url="\$a"; done
printf '%s' "\$url" > "$dir/curl.url"
EOF
  cat > "$dir/tar" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$dir"/uname "$dir"/apt-get "$dir"/curl "$dir"/tar
}

echo "== unit parity (heredoc == staged file) =="
for unit in barkpark-builder.service barkpark-runtime.service; do
  extract_unit "$unit" > "$TMP/$unit.heredoc"
  check "$unit: heredoc found in the script"    "[ -s '$TMP/$unit.heredoc' ]"
  check "$unit: staged file exists in deploy/systemd" "[ -s '$STAGED/$unit' ]"
  if diff -u "$STAGED/$unit" "$TMP/$unit.heredoc" > "$TMP/$unit.diff" 2>&1; then
    pass "$unit: staged file is byte-identical to the heredoc"
  else
    fail "$unit: staged file DRIFTED from the heredoc"
    cat "$TMP/$unit.diff"
  fi
done

echo "== placeholders =="
# PLATFORM is the ONLY placeholder left. jpf-w1-builder-identity deleted
# __BUILDER_TOKEN__: the builder's token file is now fixed at agent.token, the
# same shape the runtime unit has always had, so there is nothing per-box to
# substitute and no way for a stale worker.token to be selected at install time.
for side in "$SCRIPT" "$STAGED/barkpark-builder.service"; do
  check "builder platform placeholder present in $(basename "$side")" \
    "grep -q '__PLATFORM__' '$side'"
  check "builder token placeholder is GONE from $(basename "$side")" \
    "! grep -q '__BUILDER_TOKEN__' '$side'"
done
check "runtime unit carries no placeholder (fixed agent-token identity)" \
  "! grep -q '__' '$STAGED/barkpark-runtime.service'"

# The script's own sed line, replayed against the staged unit: the placeholder
# must be filled, and nothing placeholder-shaped may survive on the box.
sed_line="$(grep -F 's#__PLATFORM__#' "$SCRIPT" | head -1)"
printf '%s' "$sed_line" > "$TMP/sed_line"   # via a file: never re-expand it
check "the sed line no longer substitutes a token placeholder" \
  "! grep -qF '__BUILDER_TOKEN__' '$TMP/sed_line'"
cp "$STAGED/barkpark-builder.service" "$TMP/builder.installed"
sed_body="${sed_line#sed -i \"}"; sed_body="${sed_body%\" *}"
PLATFORM=linux/amd64 \
  bash -c "sed -i.bak \"$sed_body\" '$TMP/builder.installed'" 2>/dev/null
check "substituted unit keeps NO placeholder" "! grep -q '__' '$TMP/builder.installed'"
check "substituted unit carries the resolved platform" \
  "grep -q -- '--platform linux/amd64' '$TMP/builder.installed'"
check "substituted unit points at the box's OWN agent token" \
  "grep -q -- '--token-file /etc/barkpark/agent.token' '$TMP/builder.installed'"
check "substituted unit names NO worker token" \
  "! grep -q 'worker.token' '$TMP/builder.installed'"

echo "== go toolchain arch =="
arch_block="$(extract_block 'go-toolchain arch')"
check "the arch branch block is marked in the script" "[ -n \"\$arch_block\" ]"

go_arch_for() {
  local dir="$TMP/arch-$1"; make_fakes "$dir" "$1"
  PATH="$dir" "$BASH_BIN" -c "$arch_block
printf '%s' \"\${GO_ARCH:-}\"" 2>/dev/null
}
go_arch_rc() {
  local dir="$TMP/archrc-$1"; make_fakes "$dir" "$1"
  PATH="$dir" "$BASH_BIN" -c "set -e
$arch_block" >/dev/null 2>&1
  echo $?
}
check "x86_64 -> linux-amd64 (the bare default cx23 box)" "[ \"\$(go_arch_for x86_64)\" = 'linux-amd64' ]"
check "aarch64 -> linux-arm64"                            "[ \"\$(go_arch_for aarch64)\" = 'linux-arm64' ]"
check "unknown arch fails loudly (exit 1)"                "[ \"\$(go_arch_rc riscv64)\" = '1' ]"
check "no hardcoded go tarball arch left in the script" \
  "! grep -qE 'go[0-9.]+\.linux-(amd|arm)64\.tar\.gz' '$SCRIPT'"

# The download line itself, replayed with the branch's answer bound. GO_VERSION
# is read from the script here (the replay shell has no grep on its PATH).
curl_line="$(grep -F 'go.dev/dl/go' "$SCRIPT" | head -1)"
script_go_version="$(grep -m1 '^GO_VERSION=' "$SCRIPT" | cut -d= -f2)"
check "the script pins a GO_VERSION" "[ -n '$script_go_version' ]"
go_url_for() {
  local dir="$TMP/url-$1"; make_fakes "$dir" "$1"
  PATH="$dir" "$BASH_BIN" -c "$arch_block
GO_VERSION='$script_go_version'
$curl_line" >/dev/null 2>&1
  cat "$TMP/url-$1/curl.url" 2>/dev/null
}
check "x86 box downloads the amd64 tarball" \
  "[ \"\$(go_url_for x86_64)\" = \"https://go.dev/dl/go${script_go_version}.linux-amd64.tar.gz\" ]"
check "arm box downloads the arm64 tarball" \
  "[ \"\$(go_url_for aarch64)\" = \"https://go.dev/dl/go${script_go_version}.linux-arm64.tar.gz\" ]"

echo "== git is installed, never assumed =="
git_block="$(extract_block 'git ensure')"
check "the git-ensure block is marked in the script" "[ -n \"\$git_block\" ]"
check "git rides the bare-box apt run beside docker" \
  "grep -qE 'apt-get install .*docker\.io git' '$SCRIPT'"
check "the probe header prints git --version" "grep -qx 'git --version' '$SCRIPT'"

# git MISSING (PATH holds only the fakes): the block must install it and the
# probe must then succeed.
dir="$TMP/git-absent"; make_fakes "$dir"
out="$(PATH="$dir" "$BASH_BIN" -c "$git_block" 2>&1)"; rc=$?
check "git absent: block exits 0"                 "[ '$rc' = '0' ]"
check "git absent: apt-get install git was run"   "grep -q 'apt-get install .* git' '$TMP/git-absent/apt.log'"
check "git absent: probe then reports a version"  "[ -n \"\$(printf %s \"$out\" | grep 'git version')\" ]"

# git PRESENT: no apt run at all (idempotent re-install on a warm box).
dir="$TMP/git-present"; make_fakes "$dir"
printf '%s\n' '#!/bin/sh' 'echo "git version 2.40.0-preinstalled"' > "$dir/git"
chmod +x "$dir/git"
out="$(PATH="$dir" "$BASH_BIN" -c "$git_block" 2>&1)"; rc=$?
check "git present: block exits 0"                "[ '$rc' = '0' ]"
check "git present: no apt-get invoked"           "[ ! -s '$TMP/git-present/apt.log' ]"
check "git present: pre-existing git reported"    "[ -n \"\$(printf %s \"$out\" | grep '2.40.0-preinstalled')\" ]"

echo "== self-containment =="
check "the script reads no repo file at run time (units stay inlined)" \
  "! grep -qE '(cp|cat|install) +[^|]*deploy/systemd/' '$SCRIPT'"
# INVERTED BY jpf-w1-builder-identity. This check used to assert the OPPOSITE —
# that the worker.token preference stayed in the script, so a hand-fixed box
# would keep its shared fleet credential across reinstalls. That is the hazard,
# not the safety: the preference is gone and reinstalls must CONVERGE on the
# box's own agent token. Flipping the assertion rather than deleting it keeps a
# guard on the seam, so a revert reds here by name instead of passing silently.
# Comments are stripped first, deliberately: the script KEEPS a paragraph
# explaining what the worker.token preference was and why it was deleted, and
# that history is worth more than a grep that cannot tell a warning from a
# reintroduction. What must not come back is an EXECUTABLE reference.
check "no executable line in the install script references worker.token" \
  "! grep -v '^[[:space:]]*#' '$SCRIPT' | grep -q 'worker.token'"
check "the builder unit in the script names the box's own agent token" \
  "grep -q -- '--token-file /etc/barkpark/agent.token' '$SCRIPT'"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
