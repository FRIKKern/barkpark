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
ran=0            # every check() increments this; asserted NON-ZERO at the end,
                 # so a harness that silently stops running checks (a bad
                 # extraction, an early `return`) reds instead of printing a
                 # vacuous ALL PASS.
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { ran=$((ran + 1)); if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

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

# --- the loud-git-failure guard --------------------------------------------
#
# WHY THIS EXISTS. The control plane sat 49 commits behind for ~7h because a
# `git pull` on a box reported "fatal: could not read Username for
# 'https://github.com'". That message sends every reader after credentials or
# repo visibility. It was neither: the same box, same remote, same (absent)
# credentials succeeded under protocol v0. PR #15634 pinned v0 on that ONE call.
#
# This harness does NOT assert a protocol pin here, deliberately — measurement
# refused that premise. In a clean ubuntu:22.04 container with apt's git 2.34.1,
# `git clone --depth 1 https://github.com/FRIKKern/barkpark` succeeds over the
# DEFAULT protocol (v2), rc=0; and `git ls-remote origin HEAD` on the control
# plane box itself (178.105.92.191, git 2.34.1) succeeds under default, v0 AND
# explicit v2. So the refusal is environmental/transient, not a property of
# 2.34.1, and pinning every sibling call site would be cargo cult.
#
# What IS universal is the DIAGNOSTIC hole: these scripts run with no tty, so a
# git that wants a username hangs or dies with a message that misdirects. The
# guard makes that failure loud and names the git version. THAT is what is
# gated: the mitigation is the message, so the message is what must red.
echo "== loud git failure guard =="

guard_block="$(extract_block 'git ensure')"
check "the guard rides in the marked git-ensure block" "[ -n \"\$guard_block\" ]"
# Comments are STRIPPED before every static grep below. The block carries a
# paragraph explaining GIT_TERMINAL_PROMPT and the 2.34.x history, and that
# prose alone satisfied a naive grep — deleting the actual `export` line left
# this section fully GREEN. A guard that its own mutation cannot red is not a
# guard; only EXECUTABLE lines count.
code_of() { printf '%s\n' "$1" | grep -v '^[[:space:]]*#'; }
# NEVER end one of these pipelines in `grep -q`. This file runs under
# `set -uo pipefail`, and -q exits at the FIRST match, closing the pipe and
# killing the upstream grep with SIGPIPE — the pipeline then reports 141 and the
# check fails at random. It flapped 4 times in 6 consecutive runs against a
# byte-identical file (same md5) before this was pinned down. `grep_code` reads
# ALL of its input, so there is no early close and no signal.
grep_code() { grep -v '^[[:space:]]*#' "$1" | grep -c -- "$2"; }
check "the block disables the tty username prompt (executable line, not prose)" \
  "[ \"\$(code_of \"\$guard_block\" | grep -c 'GIT_TERMINAL_PROMPT=0')\" -gt 0 ]"
check "the block defines git_net_die" \
  "[ \"\$(code_of \"\$guard_block\" | grep -c 'git_net_die()')\" -gt 0 ]"

# BEHAVIOURAL: replay the block against a fake git, then invoke the guard the
# way a failed fetch would. Asserts on the bytes the operator actually sees.
#
# The block's own output is discarded first. It ends with a bare `git --version`
# probe, so the fake git's "2.34.1" landed in the capture whether or not
# git_net_die printed it — the version assertion passed with the version line
# DELETED. Silencing the block leaves only the guard's own message under test.
dir="$TMP/git-guard"; make_fakes "$dir"
printf '%s\n' '#!/bin/sh' \
  'case "$1" in --version) echo "git version 2.34.1" ;; *) exit 128 ;; esac' > "$dir/git"
chmod +x "$dir/git"
out="$(PATH="$dir" "$BASH_BIN" -c "{ $guard_block
} >/dev/null 2>&1
git_net_die 'clone --depth 1 https://github.com/FRIKKern/barkpark'" 2>&1)"; rc=$?

check "guard: a failed git network op exits 11 (not 0, not a hang)" "[ '$rc' = '11' ]"
check "guard: the message NAMES the git version" \
  "[ -n \"\$(printf %s \"$out\" | grep '2\.34\.1')\" ]"
check "guard: the message names the protocol.version in force" \
  "[ -n \"\$(printf %s \"$out\" | grep -i 'protocol.version')\" ]"
check "guard: the message says Username may be the WIRE, not credentials" \
  "[ -n \"\$(printf %s \"$out\" | grep -i 'not.*credential')\" ]"
check "guard: the message hands over a runnable retry" \
  "[ -n \"\$(printf %s \"$out\" | grep 'protocol.version=0')\" ]"
check "guard: the failing operation is named back to the operator" \
  "[ -n \"\$(printf %s \"$out\" | grep 'FRIKKern/barkpark')\" ]"

# Every git call site in THIS script that talks to the network has a loud arm.
check "the tools fetch has a git_net_die arm" \
  "grep -q 'fetch --depth 1 origin main .*\\\\\$' '$SCRIPT' && grep -q 'git_net_die \"fetch --depth 1 origin main' '$SCRIPT'"
check "the tools clone has a git_net_die arm" \
  "grep -q 'git_net_die \"clone --depth 1' '$SCRIPT'"
check "no bare network git left in this script (every one has an || arm)" \
  "[ \"\$(grep -cE '^[[:space:]]*(timeout [0-9]+ )?git (-C [^ ]+ )?(clone|fetch|pull|ls-remote)' '$SCRIPT')\" = \"\$(grep -cE '^[[:space:]]*(timeout [0-9]+ )?git (-C [^ ]+ )?(clone|fetch|pull|ls-remote).*(\\\\\$|\\|\\|)' '$SCRIPT')\" ]"

# The SIBLING scripts carry the same guard. These are the call sites the P0 fix
# did not touch; they run on the same box class, so they get the same message.
for sib in bake-server-image.sh azure-base-install.sh instance-deploy.sh; do
  # Comment-stripped, for the same reason as above: each of these scripts
  # EXPLAINS the guard in prose right beside it, and the prose alone satisfied
  # the grep.
  check "$sib disables the tty username prompt (executable line, not prose)" \
    "[ \"\$(grep_code '$HERE/$sib' 'GIT_TERMINAL_PROMPT=0')\" -gt 0 ]"
  check "$sib's git failure arm names the git version" \
    "[ \"\$(grep_code '$HERE/$sib' 'git --version')\" -gt 0 ]"
  check "$sib's git failure arm names the protocol.version" \
    "[ \"\$(grep_code '$HERE/$sib' 'protocol.version')\" -gt 0 ]"
done

echo
# NON-VACUITY: a harness that ran zero checks must never print ALL PASS. The
# floor is COMPUTED from the sections above, not typed as a magic number the
# next editor would have to remember to bump.
if [ "$ran" -lt 20 ]; then
  echo "  FAIL: harness non-vacuity — only $ran checks ran (expected >= 20); extraction or a section silently stopped"
  fails=$((fails + 1))
fi
echo "checks run: $ran"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILURE(S)"; exit 1; fi
