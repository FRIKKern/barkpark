#!/usr/bin/env bash
# Hermetic behavioral regression for install-cli.sh's PATH postcondition.
#
# No real network, no writes outside an isolated $TMP: a fake `curl` (shadowing
# the real one on a PATH-only bin dir) "downloads" a fake bp binary, the install
# dir + $HOME are throwaway, and every network fetch is appended to DANGER_LOG.
# The proofs, one per acceptance obligation:
#   (a) after a simulated install, a FRESHLY-SPAWNED child shell resolves bp;
#   (b) the login rc file was patched (once) when bp started off-PATH;
#   (c) re-running the installer does NOT double-append the rc stanza;
#   (d) the GUI-agent stale-PATH caveat is printed;
#   (e) the Windows mirror (install-cli.ps1) carries the same verify + caveat.
#
# Templated on scripts/fetch-prebuilt.test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; find "$TMP" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

# ── Fakes: a curl that serves a fake bp binary; checksums.txt 404s so the
# installer takes its documented warn-and-continue branch (checksum policy is
# covered elsewhere — this test is about the PATH postcondition). ────────────
FAKE="$TMP/fakebin"
mkdir -p "$FAKE"

# The "released" bp: a tiny executable so `command -v bp` in a child shell and
# the installer's `bp version` readout both succeed.
FAKE_BP_SRC="$TMP/fake-bp"
cat > "$FAKE_BP_SRC" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = version ] && { echo '{"cli_version":"9.9.9-test"}'; exit 0; }
exit 0
EOF

cat > "$FAKE/curl" <<EOF
#!/usr/bin/env bash
# Fake curl: understands the installer's two GETs. -o OUT names the sink.
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *)  url="\$1"; shift ;;
  esac
done
echo "curl \$url" >> "\$DANGER_LOG"
case "\$url" in
  *checksums.txt) exit 22 ;;               # simulate 404 -> installer warns
  *) cp "$FAKE_BP_SRC" "\$out" ;;
esac
exit 0
EOF
chmod +x "$FAKE"/* "$FAKE_BP_SRC"

DANGER_LOG="$TMP/danger.log"

# A genuinely fresh child shell — the "new terminal" a real user opens. env -i
# scrubs the environment so the ONLY way bp resolves is via the rc file this
# login shell reads. Mirrors what install-cli.sh's own probe asserts, but is
# computed INDEPENDENTLY here so the proof does not lean on installer internals.
child_shell_resolves_bp() {
  local home="$1"
  env -i HOME="$home" TERM=dumb bash -l -c 'command -v bp >/dev/null 2>&1'
}

run_install() {
  # $1 = HOME, $2 = BIN_DIR, $3 = output file. SHELL=bash so the installer maps
  # to a bash rc file and probes with bash -l (no live network: fake curl only).
  env -i PATH="$FAKE:/usr/bin:/bin" HOME="$1" SHELL="/bin/bash" \
    DANGER_LOG="$DANGER_LOG" BARKPARK_CLI_RELEASE_BASE="https://example.invalid/rel" \
    BARKPARK_BIN_DIR="$2" \
    /bin/sh "$HERE/install-cli.sh" > "$3" 2>&1
}

# ════════════════════════════════════════════════════════════════════════════
echo "== install onto a fresh HOME: off-PATH bp -> rc patched, clean shell finds bp =="
H1="$TMP/home1"; BIN1="$TMP/bin1"
mkdir -p "$H1" "$BIN1"
# Precondition: a brand-new terminal does NOT resolve bp (nothing installed).
check "precondition: fresh child shell does NOT resolve bp yet" \
  "! child_shell_resolves_bp '$H1'"
: > "$DANGER_LOG"
run_install "$H1" "$BIN1" "$TMP/out1.txt"
rc=$?
check "installer exits 0" "[ '$rc' = 0 ]"
check "bp binary landed in BIN_DIR" "[ -x '$BIN1/bp' ]"
# rc file selection: bash + no .bashrc/.bash_profile -> ~/.profile.
RC1="$H1/.profile"
check "login rc file (.profile) was created/patched" "[ -f '$RC1' ]"
check "rc patch carries the idempotency marker" \
  "grep -qF 'barkpark-bp path' '$RC1'"
check "rc patch exports BIN_DIR ahead of PATH" \
  "grep -qF 'export PATH=\"$BIN1:\$PATH\"' '$RC1'"
# (a) THE postcondition: a freshly-spawned child shell now resolves bp.
check "(a) a freshly-spawned child shell resolves bp after install" \
  "child_shell_resolves_bp '$H1'"
# (d) GUI-agent caveat printed.
check "(d) GUI-agent stale-PATH caveat is printed" \
  "grep -qF 'already-running agent' '$TMP/out1.txt'"
check "installer announces the rc patch" \
  "grep -qF 'added $BIN1 to PATH in $RC1' '$TMP/out1.txt'"
# Only the network fetch touched DANGER_LOG (no rogue side-effect command).
check "only curl fetches were logged (no other dangerous command)" \
  "grep -q '^curl ' '$DANGER_LOG' && ! grep -qv '^curl ' '$DANGER_LOG'"

echo "== re-run is idempotent: rc stanza is NOT double-appended =="
before_sha="$(shasum -a 256 "$RC1" | awk '{print $1}')"
marker_count_before="$(grep -cF 'barkpark-bp path' "$RC1")"
: > "$DANGER_LOG"
run_install "$H1" "$BIN1" "$TMP/out2.txt"
rc=$?
marker_count_after="$(grep -cF 'barkpark-bp path' "$RC1")"
after_sha="$(shasum -a 256 "$RC1" | awk '{print $1}')"
check "re-run exits 0" "[ '$rc' = 0 ]"
check "(c) marker appears exactly once before and after re-run" \
  "[ '$marker_count_before' = 1 ] && [ '$marker_count_after' = 1 ]"
check "(c) rc file is byte-identical after re-run (no double-append)" \
  "[ '$before_sha' = '$after_sha' ]"
check "re-run still resolves bp in a fresh child shell" \
  "child_shell_resolves_bp '$H1'"

echo "== when a fresh shell already resolves bp, no rc file is touched =="
H3="$TMP/home3"; BIN3="$TMP/bin3"
mkdir -p "$H3" "$BIN3"
# Pre-seed .profile with the export already present (simulating a prior install
# or a user who set it up by hand): installer must NOT re-patch.
printf '# barkpark-bp path (added by install-cli)\nexport PATH="%s:$PATH"\n' "$BIN3" > "$H3/.profile"
seed_sha="$(shasum -a 256 "$H3/.profile" | awk '{print $1}')"
: > "$DANGER_LOG"
run_install "$H3" "$BIN3" "$TMP/out3.txt"
rc=$?
check "seeded-rc install exits 0" "[ '$rc' = 0 ]"
check "(b) pre-satisfied PATH leaves the rc file untouched" \
  "[ '$seed_sha' = \"\$(shasum -a 256 '$H3/.profile' | awk '{print \$1}')\" ]"
check "seeded-rc install does NOT re-announce a patch" \
  "! grep -qF 'added $BIN3 to PATH' '$TMP/out3.txt'"
check "seeded-rc install still prints the GUI-agent caveat" \
  "grep -qF 'already-running agent' '$TMP/out3.txt'"

echo "== Windows mirror (install-cli.ps1) carries the same postcondition =="
PS1="$HERE/install-cli.ps1"
check "(e) ps1 spawns a fresh child process to verify PATH" \
  "grep -qF 'Test-FreshShellResolvesBp' '$PS1'"
check "(e) ps1 rebuilds PATH from the registry (Machine + User), not \$env:Path" \
  "grep -qF \"GetEnvironmentVariable('Path', 'Machine')\" '$PS1'"
check "(e) ps1 runs the probe in a -NoProfile child host" \
  "grep -qF -e '-NoProfile -NonInteractive' '$PS1'"
check "(e) ps1 prints the GUI-agent stale-PATH caveat" \
  "grep -qF \"already-running agent won't see bp\" '$PS1'"

echo "== the old string-membership PATH check is gone from install-cli.sh =="
check "install-cli.sh no longer relies on the membership-only warning" \
  "! grep -qF '*\":\${BIN_DIR}:\"*)' '$HERE/install-cli.sh'"

if [ "$fails" -ne 0 ]; then
  echo "install-cli tests: $fails failure(s)" >&2
  exit 1
fi
echo "install-cli tests: PASS"
