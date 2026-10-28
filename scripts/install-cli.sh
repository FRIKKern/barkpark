#!/bin/sh
# Barkpark `bp` CLI installer (curl|sh).
#
#   curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
#   curl -fsSL .../install-cli.sh | sh -s -- --help
#
# Detects OS + arch, downloads the matching bp-<os>-<arch> release binary,
# verifies its sha256 against the release's checksums.txt, makes it
# executable, and installs it into the bin dir.
#
# POSIX sh — runs under dash (Ubuntu /bin/sh); no bashisms.
#
# The usage text below documents the tunables (env).
# After the install it warns when another bp comes first on PATH.
set -eu

usage() {
  cat <<'EOF'
Usage: curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
       sh install-cli.sh [--help]

Installs the bp CLI for this OS and arch, checked against the release's
checksums.txt.

Environment:
  BARKPARK_BIN_DIR           Install directory. Default: $HOME/.local/bin,
                             created when missing. The install stops when the
                             directory is not writable. It never falls back.
                             The installer writes /usr/local/bin only when
                             this variable names it. Under sudo it is
                             required: ... | sudo env BARKPARK_BIN_DIR=<dir> sh
  BARKPARK_CLI_VERSION       Release to install, such as 1.26.11. Default: the
                             newest cli-v release.
  BARKPARK_CLI_RELEASE_BASE  URL of a directory with the bp-<os>-<arch> assets
                             and checksums.txt. Overrides BARKPARK_CLI_VERSION.

When a bp is already at the target, the installer prints its version and the
new version before it replaces it. When a new shell does not find the
directory on PATH, the installer adds an export line to the shell's rc file.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    *) echo "install-cli: unknown argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
done

REPO_URL="https://github.com/FRIKKern/barkpark"

if [ -n "${BARKPARK_CLI_RELEASE_BASE:-}" ]; then
  RELEASE_BASE="$BARKPARK_CLI_RELEASE_BASE"
elif [ -n "${BARKPARK_CLI_VERSION:-}" ]; then
  RELEASE_BASE="${REPO_URL}/releases/download/cli-v${BARKPARK_CLI_VERSION}"
else
  # Resolve the newest cli-v* release via the GitHub API instead of trusting
  # `releases/latest`: this repo also publishes build-<sha> server-artifact
  # releases (no bp assets), and one of those holding "latest" 404s every
  # unpinned install. The [0-9.]* charset skips prereleases like cli-v1.2.0-rc.1
  # (matching the old releases/latest rule). The highest version wins, not the
  # first listed: on 2026-10-28 the API listed cli-v1.26.9 before cli-v1.26.11.
  # per_page=100 is the API maximum. release-artifact.yml cuts several build-<sha>
  # releases a day, so a page of 30 can hold no cli-v release at all, and the
  # install then falls back to releases/latest.
  api_url="https://api.github.com/repos/FRIKKern/barkpark/releases?per_page=100"
  cli_tag="$( { curl -fsSL "$api_url" 2>/dev/null || wget -qO- "$api_url" 2>/dev/null || true; } \
    | sed -n 's/.*"tag_name"[: ]*"\(cli-v[0-9.]*\)".*/\1/p' \
    | sort -t . -k 1.6,1n -k 2,2n -k 3,3n | tail -n 1 )"
  if [ -n "$cli_tag" ]; then
    RELEASE_BASE="${REPO_URL}/releases/download/${cli_tag}"
  else
    RELEASE_BASE="${REPO_URL}/releases/latest/download"
  fi
fi
BIN_DIR="${BARKPARK_BIN_DIR:-}"
BIN_DIR_SOURCE="BARKPARK_BIN_DIR"

err() { echo "install-cli: $*" >&2; }
die() { err "$*"; exit 1; }

# ── Detect OS ────────────────────────────────────────────────────────────────
os_raw="$(uname -s)"
case "$os_raw" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *) die "unsupported OS '$os_raw' (supported: Darwin, Linux)" ;;
esac

# ── Detect arch ──────────────────────────────────────────────────────────────
arch_raw="$(uname -m)"
case "$arch_raw" in
  arm64|aarch64)  arch="arm64" ;;
  x86_64|amd64)   arch="amd64" ;;
  *) die "unsupported arch '$arch_raw' (supported: arm64/aarch64, x86_64/amd64)" ;;
esac

asset="bp-${os}-${arch}"
url="${RELEASE_BASE%/}/${asset}"

# ── Pick a downloader ────────────────────────────────────────────────────────
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
else
  die "neither curl nor wget found on PATH"
fi

# ── Resolve a writable install dir ───────────────────────────────────────────
ensure_writable_dir() {
  if [ -d "$1" ] && [ -w "$1" ]; then
    return 0
  fi
  if [ ! -d "$1" ]; then
    mkdir -p "$1" 2>/dev/null && [ -w "$1" ] && return 0
  fi
  return 1
}

if [ -n "$BIN_DIR" ]; then
  # An explicit setting is honoured or the install stops. A silent fallback
  # put bp somewhere the caller did not ask for.
  ensure_writable_dir "$BIN_DIR" || die "BARKPARK_BIN_DIR='$BIN_DIR' is not writable. Fix its permissions, run with sudo, or pick another directory."
else
  # The default is under HOME. It is never a system directory and never the
  # directory of another bp on PATH: setup run 6 (2026-10-28) overwrote two
  # bp binaries outside its HOME under the old rule.
  [ -n "${HOME:-}" ] || die "HOME is not set. Set HOME, or set BARKPARK_BIN_DIR."
  # Under sudo the default would land in root's home, which the calling user's
  # shell never searches. Older `bp upgrade` builds print `| sudo sh`.
  if [ -n "${SUDO_USER:-}" ] && [ "$(id -u)" = 0 ]; then
    die "running under sudo with no BARKPARK_BIN_DIR, so bp would go to ${HOME}/.local/bin. Name the directory, such as: curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sudo env BARKPARK_BIN_DIR=/usr/local/bin sh"
  fi
  BIN_DIR="${HOME}/.local/bin"
  BIN_DIR_SOURCE="the default; set BARKPARK_BIN_DIR for another directory"
  ensure_writable_dir "$BIN_DIR" || die "cannot create or write '$BIN_DIR'. Set BARKPARK_BIN_DIR to a writable directory."
fi
echo "install-cli: installing into ${BIN_DIR} (${BIN_DIR_SOURCE})"

dest="${BIN_DIR%/}/bp"
tmp="$(mktemp "${TMPDIR:-/tmp}/bp-install.XXXXXX")"
sums_tmp="$(mktemp "${TMPDIR:-/tmp}/bp-sums.XXXXXX")"
trap 'rm -f "$tmp" "$sums_tmp"' EXIT

echo "install-cli: detected ${os}/${arch}"
echo "install-cli: downloading ${url}"
if ! fetch "$url" "$tmp"; then
  err "download failed from ${url}"
  err "if this is a fresh fork or no CLI release has been published yet,"
  err "build from source instead:  git clone ${REPO_URL} && cd barkpark && make cli-build"
  exit 1
fi

# ── Verify sha256 against the release's checksums.txt ────────────────────────
# Hard-fail on mismatch or a missing entry; warn-and-continue only when
# checksums.txt itself is absent (custom mirrors that pre-date checksums).
sums_url="${RELEASE_BASE%/}/checksums.txt"
if fetch "$sums_url" "$sums_tmp" 2>/dev/null; then
  expected="$(grep " ${asset}$" "$sums_tmp" | awk '{print $1}')"
  [ -n "$expected" ] || die "checksums.txt has no entry for ${asset}"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$tmp" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$tmp" | awk '{print $1}')" # macOS
  fi
  [ "$actual" = "$expected" ] || die "checksum mismatch for ${asset} — refusing to install (expected ${expected}, got ${actual})"
  echo "install-cli: checksum OK (${actual})"
else
  err "WARNING: checksums.txt not found at ${sums_url}; skipping verification"
fi

chmod +x "$tmp"

# Best-effort version readout (non-TTY `bp version` emits JSON).
bp_version_of() {
  "$1" version </dev/null 2>/dev/null | sed -n 's/.*"cli_version"[: ]*"\([^"]*\)".*/\1/p' | head -n 1
}
ver="$(bp_version_of "$tmp" || true)"
if [ -e "$dest" ]; then
  old_ver="$(bp_version_of "$dest" || true)"
  echo "install-cli: replacing ${dest}: bp ${old_ver:-of unknown version} -> bp ${ver:-of unknown version}"
fi
mv "$tmp" "$dest"
trap 'rm -f "$sums_tmp"' EXIT
if [ -n "$ver" ]; then
  echo "install-cli: installed bp ${ver} -> ${dest}"
else
  echo "install-cli: installed bp -> ${dest}"
fi

# ── PATH postcondition (clean-shell verify + rc patch) ───────────────────────
# A string-membership test (`case ":$PATH:" in *":$BIN_DIR:"*`) only proves
# THIS process can see bp. It says nothing about the user's NEXT terminal,
# which starts a FRESH shell that builds PATH from rc files — not this
# installer's in-memory PATH. An in-process `export PATH` dies with this
# process. So verify the real postcondition: spawn a fresh login shell with
# BIN_DIR scrubbed from the PATH we hand it, and confirm it resolves `bp`.
# If it can't, patch the login rc file with the export stanza and re-verify.

PATH_MARKER="# barkpark-bp path (added by install-cli)"

# Emit $PATH with every literal occurrence of $BIN_DIR removed, so an in-process
# export can never mask a missing rc entry during the probe.
path_without_bindir() {
  printf '%s' "${PATH}" | tr ':' '\n' | grep -vxF "$BIN_DIR" | paste -sd ':' -
}

# Resolve a probe shell that supports `-l` (login). bash/zsh do; dash rejects
# it, so fall back to bash when the login shell is a bare POSIX sh.
probe_shell="${SHELL:-/bin/sh}"
[ -x "$probe_shell" ] || probe_shell="/bin/sh"
login_shell_name="$(basename "$probe_shell" 2>/dev/null || echo sh)"
case "$login_shell_name" in
  bash|zsh) probe_login="-l" ;;
  *)
    if command -v bash >/dev/null 2>&1; then
      probe_shell="$(command -v bash)"; login_shell_name="bash"; probe_login="-l"
    else
      probe_login=""   # bare POSIX sh: no login flag (dash errors on -l)
    fi
    ;;
esac

# Which bp does a fresh login shell run? BIN_DIR is scrubbed from the handed-in
# PATH, so the only ways bp can resolve are (a) a system dir already on PATH
# (login init / path_helper) or (b) the rc file's export — exactly what the
# user's next terminal sees. $1 = rc file to source (may be empty/absent).
# Prints the path, or nothing.
fresh_shell_bp() {
  env -i HOME="${HOME}" PATH="$(path_without_bindir)" \
    "$probe_shell" $probe_login -c \
    '[ -n "${1:-}" ] && [ -r "$1" ] && . "$1"; command -v bp 2>/dev/null' \
    bp-probe "${1:-}" 2>/dev/null | tail -n 1
}

# True when a fresh shell runs the bp this script just installed.
probe_resolves_bp() {
  [ "$(fresh_shell_bp "${1:-}")" = "$dest" ]
}

# Map the login shell to the rc file a new interactive terminal reads.
rc_file_for_shell() {
  case "$1" in
    zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if   [ -f "$HOME/.bashrc" ];       then echo "$HOME/.bashrc"
          elif [ -f "$HOME/.bash_profile" ]; then echo "$HOME/.bash_profile"
          else echo "$HOME/.profile"; fi ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

# Append the export stanza once (idempotent on PATH_MARKER — never double-add).
patch_rc_file() {
  _rc="$1"
  if [ -f "$_rc" ] && grep -qF "$PATH_MARKER" "$_rc" 2>/dev/null; then
    return 0
  fi
  {
    printf '\n%s\n' "$PATH_MARKER"
    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
  } >> "$_rc"
}

rc_file="$(rc_file_for_shell "$login_shell_name")"
if probe_resolves_bp "$rc_file"; then
  : # a fresh shell already runs this bp (system dir on PATH, or rc already set)
elif patch_rc_file "$rc_file" && probe_resolves_bp "$rc_file"; then
  echo "install-cli: added ${BIN_DIR} to PATH in ${rc_file} (new terminals will find bp)"
else
  shadow="$(fresh_shell_bp "$rc_file")"
  if [ -n "$shadow" ]; then
    shadow_ver="$("$shadow" version </dev/null 2>/dev/null | sed -n 's/.*"cli_version"[: ]*"\([^"]*\)".*/\1/p' || true)"
    err "WARNING — another bp comes first on PATH: ${shadow}${shadow_ver:+ (version ${shadow_ver})}."
    err "          A new terminal runs that one, not ${dest}. Remove it, or rerun with"
    err "          BARKPARK_BIN_DIR=$(dirname "$shadow") to replace it."
  else
    err "NOTE — ${BIN_DIR} is not on your PATH and a fresh shell still can't"
    err "       resolve bp. Add it manually:"
    err "         export PATH=\"${BIN_DIR}:\$PATH\""
  fi
fi
# This shell's PATH can differ from a new terminal's. Name a shadowing bp here
# too, since the next command in this shell runs it.
if ! printf '%s' "${PATH}" | tr ':' '\n' | grep -qxF "$BIN_DIR"; then
  echo "install-cli: ${BIN_DIR} is not on this shell's PATH. To run bp in this shell now:"
  echo "               export PATH=\"${BIN_DIR}:\$PATH\""
fi
current_bp="$(command -v bp 2>/dev/null || true)"
if [ -n "$current_bp" ] && [ "$current_bp" != "$dest" ] && [ "$current_bp" != "${shadow:-}" ]; then
  err "WARNING — in this shell, bp runs ${current_bp}, not ${dest}. Remove it or put ${BIN_DIR} first on PATH."
fi

# GUI-agent stale-PATH caveat: a Cursor / Claude Desktop / VS Code process
# spawns `bp mcp serve` with the PATH captured when the AGENT launched, so an
# already-running agent won't see bp until it is fully quit and reopened.
echo "install-cli: NOTE — a GUI-launched agent (Cursor, Claude Desktop, VS Code)"
echo "             runs 'bp mcp serve' with the PATH it captured at its own"
echo "             launch, so an already-running agent won't see bp until you"
echo "             fully quit and reopen it (a new shell alone is not enough)."

echo "install-cli: done."
echo ""
echo "  Get started:   bp          (first run launches the setup wizard)"
echo "  Verify:        bp version"
