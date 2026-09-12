# shellcheck shell=bash
# pds-live-lib.sh — the vocabulary the two pds-live L1 runners share.
#
# SOURCED, never executed. Both credential-gated live-proof runners
# (scripts/pds-live-hetzner-placement-group.sh and
# scripts/pds-live-bp-write-receipt.sh) held byte-identical copies of every
# function below. That is the failure mode this file exists to close: a fix
# applied to one copy silently did not reach the other, which is exactly how
# "extend the instrument, do not write a second one" got half-applied.
#
# WHAT DOES NOT BELONG HERE. Only functions whose bodies were ALREADY identical
# in both runners. apparatus_or_refuse and shape_ok are deliberately absent:
# they LOOK shared and are not — each runner checks different symbols and a
# different receipt shape, and folding them together would be a behaviour
# change wearing an extraction's clothes. build_bp calls apparatus_or_refuse by
# name and each runner still defines its own; bash resolves it at call time.
#
# CONTRACT the sourcing script owes this file:
#   SELF     basename "$0", used in every refusal line
#   ART      the artifact dir (must exist before st_case runs)
#   REPO_ROOT, GO_BIN   used by build_bp
#   apparatus_or_refuse a function; build_bp calls it
#   ST_FAIL             initialised to 0 before the first st_case
# and this file sets ST_LAST_OUT, which --selftest arms read afterwards.
#
# bash 3.2 compatible (macOS system bash). No `set -e` changes: callers own
# their errexit state, and st_case restores whatever it found.

# ── vocabulary ───────────────────────────────────────────────────────────────
#
# Three outcomes, and the refusal is a first-class one. "REFUSE" is the word; a
# quiet no-op has no spelling in these scripts on purpose.

say()    { printf '%s\n' "$*"; }
step()   { printf '\n== %s\n' "$*"; }
ok()     { printf '  PASS    %s\n' "$*"; }
refuse() { printf '\n%s: REFUSE — %s\n' "$SELF" "$*" >&2; exit 3; }
failed() { printf '\n%s: FAIL — %s\n' "$SELF" "$*" >&2; exit 1; }
usage()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 2; }

# jsonq FILE EXPR — evaluate a python expression over the parsed body `d`.
# Exits non-zero if the body is not JSON at all, which is itself an assertion.
jsonq() {
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("not JSON: %s\n" % e)
    sys.exit(9)
v = eval(sys.argv[2])
print("" if v is None else v)
' "$1" "$2"
}

# ── the bp under proof ───────────────────────────────────────────────────────
#
# BUILT FROM THIS WORKTREE, never the installed binary: an installed bp that
# predates the apparatus would exercise pre-fence code and prove nothing about
# the receipts under test. The apparatus check itself is per-runner
# (apparatus_or_refuse, defined by the sourcing script).

BP=""

build_bp() {
  if [ -n "${PDS_LIVE_BP:-}" ]; then
    BP="$PDS_LIVE_BP"
    [ -x "$BP" ] || refuse "PDS_LIVE_BP=$BP is not executable"
    return 0
  fi
  apparatus_or_refuse
  [ -d "$REPO_ROOT/cmd/barkpark" ] || refuse "no $REPO_ROOT/cmd/barkpark — note ./cmd/bp DOES NOT EXIST; the binary's package is cmd/barkpark"
  BP="$ART/bp"
  ( cd "$REPO_ROOT" && CC="${CC:-/usr/bin/clang}" "$GO_BIN" build -o "$BP" ./cmd/barkpark ) \
    || refuse "go build ./cmd/barkpark failed — refusing to prove anything with a binary this worktree could not produce"
}

# st_case LABEL EXPECT-RC ENV… — run `$0 --preflight` under ENV and pin its rc.
#
# The rc is taken WITHOUT A PIPE: `bp … | head -1 && echo OK` prints OK at rc=0
# for a command that failed, because a pipeline's status is head's. Both
# runners' --selftest arms demonstrate that trap live rather than trusting the
# comment.
st_case() {
  local label="$1" want="$2"; shift 2
  local out="$ART/st.$$.out" rc=0
  set +e
  env "$@" "$0" --preflight >"$out" 2>&1
  rc=$?
  set -e
  local verdict="PASS"
  [ "$rc" = "$want" ] || { verdict="FAIL"; ST_FAIL=1; }
  printf '  %-6s %-58s rc=%s (want %s)\n' "$verdict" "$label" "$rc" "$want"
  printf '         %s\n' "$(grep -Eo 'REFUSE — [^.]*\.|CREDENTIAL RUNG THAT PAID: .*' "$out" | head -1 | cut -c1-120)"
  ST_LAST_OUT="$out"
  return 0
}
