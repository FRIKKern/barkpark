#!/bin/sh
# Barkpark `bp` CLI installer (curl|sh).
#
#   curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
#
# Detects OS + arch, downloads the matching bp-<os>-<arch> release binary,
# verifies its sha256 against the release's checksums.txt, makes it
# executable, and installs it into the bin dir.
#
# POSIX sh — runs under dash (Ubuntu /bin/sh); no bashisms.
#
# Tunables (env):
#   BARKPARK_CLI_VERSION       pin a release version, e.g. 1.0.1 — downloads
#                              from releases/download/cli-v<version> instead
#                              of releases/latest
#   BARKPARK_CLI_RELEASE_BASE  base URL to fetch the binary from; overrides
#                              BARKPARK_CLI_VERSION
#                              (default: GitHub latest release assets)
#   BARKPARK_BIN_DIR           install dir (default: /usr/local/bin,
#                              falls back to ~/.local/bin if not writable)
set -eu

REPO_URL="https://github.com/FRIKKern/barkpark"

if [ -n "${BARKPARK_CLI_RELEASE_BASE:-}" ]; then
  RELEASE_BASE="$BARKPARK_CLI_RELEASE_BASE"
elif [ -n "${BARKPARK_CLI_VERSION:-}" ]; then
  RELEASE_BASE="${REPO_URL}/releases/download/cli-v${BARKPARK_CLI_VERSION}"
else
  RELEASE_BASE="${REPO_URL}/releases/latest/download"
fi
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
  if [ -d "$1" ] && [ -w "$1" ]; then
    return 0
  fi
  if [ ! -d "$1" ]; then
    mkdir -p "$1" 2>/dev/null && [ -w "$1" ] && return 0
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
mv "$tmp" "$dest"
trap 'rm -f "$sums_tmp"' EXIT

# Best-effort installed-version readout (non-TTY `bp version` emits JSON).
ver="$("$dest" version </dev/null 2>/dev/null | sed -n 's/.*"cli_version"[: ]*"\([^"]*\)".*/\1/p' || true)"
if [ -n "$ver" ]; then
  echo "install-cli: installed bp ${ver} -> ${dest}"
else
  echo "install-cli: installed bp -> ${dest}"
fi

# ── PATH hint + success line ─────────────────────────────────────────────────
case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "install-cli: NOTE — ${BIN_DIR} is not on your PATH; add it, e.g.:"
     echo "             export PATH=\"${BIN_DIR}:\$PATH\"" ;;
esac

echo "install-cli: done."
echo ""
echo "  Get started:   bp          (first run launches the setup wizard)"
echo "  Verify:        bp version"
