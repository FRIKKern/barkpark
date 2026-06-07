#!/usr/bin/env bash
# Barkpark `bp` CLI installer (curl|sh).
#
#   curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
#
# Detects OS + arch, downloads the matching bp-<os>-<arch> release binary,
# makes it executable, and installs it into the bin dir.
#
# Tunables (env):
#   BARKPARK_CLI_RELEASE_BASE  base URL to fetch the binary from
#                              (default: GitHub latest release assets)
#   BARKPARK_BIN_DIR           install dir (default: /usr/local/bin,
#                              falls back to ~/.local/bin if not writable)
set -euo pipefail

RELEASE_BASE="${BARKPARK_CLI_RELEASE_BASE:-https://github.com/FRIKKern/barkpark/releases/latest/download}"
BIN_DIR="${BARKPARK_BIN_DIR:-/usr/local/bin}"

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
# Use the requested BIN_DIR when writable; otherwise fall back to ~/.local/bin.
ensure_writable_dir() {
  local dir="$1"
  if [ -d "$dir" ] && [ -w "$dir" ]; then
    return 0
  fi
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ] && return 0
  fi
  return 1
}

if ! ensure_writable_dir "$BIN_DIR"; then
  fallback="${HOME}/.local/bin"
  err "'$BIN_DIR' is not writable; falling back to '$fallback'"
  mkdir -p "$fallback" || die "could not create fallback dir '$fallback'"
  BIN_DIR="$fallback"
fi

dest="${BIN_DIR%/}/bp"
tmp="$(mktemp "${TMPDIR:-/tmp}/bp-install.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

echo "install-cli: detected ${os}/${arch}"
echo "install-cli: downloading ${url}"
fetch "$url" "$tmp" || die "download failed from ${url}"

chmod +x "$tmp"
mv "$tmp" "$dest"
trap - EXIT

echo "install-cli: installed bp -> ${dest}"

# ── PATH hint + success line ─────────────────────────────────────────────────
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "install-cli: NOTE — ${BIN_DIR} is not on your PATH; add it, e.g.:"
     echo "             export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac

echo "install-cli: done. Verify with:  bp version"
