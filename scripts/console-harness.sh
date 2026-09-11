#!/bin/sh
#
# console-harness.sh — run the console unit harness on the Node the console
# DECLARES, on a host whose default Node is something else.
#
# WHY THIS EXISTS (Cloud Console Hardening wave 61,
# cchi-w61-bl-a-local-harness-green-is-not-the-ci-green)
# ------------------------------------------------------------------
# `cloud/priv/static/__app.test.mjs` now carries a runtime self-check: it reds
# BY NAME when the running major is not the one `cloud/priv/static/__node-version`
# declares. That test is the only mechanism that makes a LOCAL green and the CI
# green the same statement — but it turns every bare `node --test` on a host
# whose default Node is a different major into a red, and two scaffy commands
# (`ensure-console-hook-zones`, `add-console-helper`) close on exactly that
# command as their `ASSERT CMD`. The scaffy engine applies its ops BEFORE it
# asserts, so on a virgin tree a failing assert leaves the zone WRITTEN and
# reports `ok:false` with rc=5.
#
# So the assert needs a command that RESOLVES the declared runtime instead of
# inheriting whatever is on PATH. That is this script. Point both ASSERT CMDs at
# it (`sh scripts/console-harness.sh`) and the run returns rc=0 under a
# node-22 PATH.
#
# THE BANNER IS MEASURED, NEVER DECLARED
# --------------------------------------
# The prototype of this script printed `Node 20 via .../v22.22.0/bin/node` — the
# DECLARED major beside a RESOLVED path it never checked. That is the very
# defect this epic is named for, committed in the instrument's own output. The
# banner below prints the major read back out of `"$node" --version`, so when
# NODE_BIN points at the wrong runtime the banner SAYS SO and the self-check
# reds underneath it. Nothing here reports a number it did not measure.
#
# HOW IT LOSES — the three ways, all intentional:
#   · NODE_BIN set to a binary of the wrong major -> the banner reports that
#     major, marks it MISMATCH, and the harness runs anyway so the in-file
#     self-check produces the authoritative red. An explicit override is
#     honoured, never silently corrected.
#   · NODE_BIN set to something that is not an executable -> exit 2, named.
#   · No candidate of the declared major anywhere -> exit 2 with a named
#     refusal that LISTS where it looked. It never falls back to the default
#     Node and calls that a pass.
#
# USAGE
#   sh scripts/console-harness.sh              # resolve + run the harness
#   sh scripts/console-harness.sh --resolve    # print the resolved binary, run nothing
#   sh scripts/console-harness.sh --selftest   # prove it can lose
#
# EXIT: 0 harness green · 1 harness red (incl. the runtime self-check) ·
#       2 REFUSED to run (no declared runtime found / unusable NODE_BIN /
#       unreadable or malformed declaration).

# `set -u` only, deliberately. Every failure path in this script is handled by
# name through `refuse`, and `set -e` would turn the ordinary `[ -x "$c" ] &&
# printf` probes in `candidates` into silent early exits — a runner that dies
# without a verdict is the shape this whole wave exists to delete.
set -u

ROOT="${CONSOLE_HARNESS_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
DECL_REL="cloud/priv/static/__node-version"
TEST_REL="cloud/priv/static/__app.test.mjs"

refuse() {
  echo "console-harness: REFUSED — $*" >&2
  exit 2
}

# The major a binary actually reports. Empty when it is not a runnable node.
major_of() {
  "$1" --version 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\)\..*$/\1/p' | head -n 1
}
version_of() {
  "$1" --version 2>/dev/null | head -n 1
}

read_declaration() {
  [ -f "$ROOT/$DECL_REL" ] || refuse "no runtime declaration at $DECL_REL (root $ROOT)"
  d="$(tr -d ' \t\r\n' < "$ROOT/$DECL_REL")"
  case "$d" in
    '' ) refuse "$DECL_REL is empty; it must hold a bare Node major" ;;
    *[!0-9]* ) refuse "$DECL_REL holds '$d', which is not a bare Node major" ;;
  esac
  printf '%s\n' "$d"
}

# Every place a Node of a given major plausibly lives on a developer box or a
# runner. Printed one per line; non-existent entries are simply skipped by the
# caller, so this list is allowed to be optimistic.
candidates() {
  want="$1"
  # 1. whatever `node` is on PATH (often the wrong major — that is the point)
  p="$(command -v node 2>/dev/null || true)"
  [ -n "$p" ] && printf '%s\n' "$p"
  # 2. nvm
  nvm_dir="${CONSOLE_HARNESS_NVM_DIR:-${NVM_DIR:-$HOME/.nvm}}"
  for c in "$nvm_dir"/versions/node/v"$want".*/bin/node; do
    [ -x "$c" ] && printf '%s\n' "$c"
  done
  # 3. fnm
  fnm_dir="${CONSOLE_HARNESS_FNM_DIR:-${FNM_DIR:-$HOME/.local/share/fnm}}"
  for c in "$fnm_dir"/node-versions/v"$want".*/installation/bin/node; do
    [ -x "$c" ] && printf '%s\n' "$c"
  done
  # 4. volta
  volta_home="${CONSOLE_HARNESS_VOLTA_HOME:-${VOLTA_HOME:-$HOME/.volta}}"
  for c in "$volta_home"/tools/image/node/"$want".*/bin/node; do
    [ -x "$c" ] && printf '%s\n' "$c"
  done
  # 5. asdf
  asdf_dir="${CONSOLE_HARNESS_ASDF_DIR:-${ASDF_DATA_DIR:-$HOME/.asdf}}"
  for c in "$asdf_dir"/installs/nodejs/"$want".*/bin/node; do
    [ -x "$c" ] && printf '%s\n' "$c"
  done
  # 6. homebrew's versioned formulae, both prefixes
  for c in /opt/homebrew/opt/node@"$want"/bin/node /usr/local/opt/node@"$want"/bin/node; do
    [ -x "$c" ] && printf '%s\n' "$c"
  done
  # 7. a plainly-named sibling on PATH (`node20`, `node22`)
  p="$(command -v "node$want" 2>/dev/null || true)"
  [ -n "$p" ] && printf '%s\n' "$p"
  return 0
}

looked_in() {
  want="$1"
  echo "  PATH node, \$NVM_DIR/versions/node/v$want.*, \$FNM_DIR/node-versions/v$want.*," >&2
  echo "  \$VOLTA_HOME/tools/image/node/$want.*, \$ASDF_DATA_DIR/installs/nodejs/$want.*," >&2
  echo "  /opt/homebrew/opt/node@$want, /usr/local/opt/node@$want, node$want on PATH" >&2
}

resolve_node() {
  want="$1"
  if [ -n "${NODE_BIN:-}" ]; then
    # An explicit override is HONOURED, not corrected. If it is the wrong major
    # the banner will say so and the harness's own self-check will red — which
    # is how this script is proven able to lose.
    [ -x "$NODE_BIN" ] || refuse "NODE_BIN='$NODE_BIN' is not an executable"
    [ -n "$(major_of "$NODE_BIN")" ] || refuse "NODE_BIN='$NODE_BIN' does not answer \`--version\` like a node"
    printf '%s\n' "$NODE_BIN"
    return 0
  fi
  candidates "$want" | while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -x "$c" ] || continue
    if [ "$(major_of "$c")" = "$want" ]; then
      printf '%s\n' "$c"
      break
    fi
  done
  return 0
}

banner() {
  node="$1"; want="$2"
  # MEASURED, not declared. Both numbers on this line are read back out of the
  # binary that is about to run.
  ver="$(version_of "$node")"
  got="$(major_of "$node")"
  if [ "$got" = "$want" ]; then
    echo "console-harness: running Node $got ($ver) from $node — matches $DECL_REL ($want)"
  else
    echo "console-harness: running Node $got ($ver) from $node — MISMATCH: $DECL_REL declares $want" >&2
    echo "console-harness: proceeding anyway; the harness's own runtime self-check is the authority and will red." >&2
  fi
}

selftest() {
  # Every arm runs THIS script in a child, so what is proven is the shipped
  # behaviour and not a re-implementation of it beside itself. CONSOLE_HARNESS_ROOT
  # is passed explicitly because arm 1 strips PATH, and the default root
  # derivation shells out to `dirname`.
  self="$ROOT/scripts/console-harness.sh"
  want="$(read_declaration)"
  pass=0; fail=0
  ok()   { pass=$((pass + 1)); echo "  ok   — $1"; }
  bad()  { fail=$((fail + 1)); echo "  FAIL — $1" >&2; }

  # 1. THE REFUSAL ARM — no Node of the declared major reachable anywhere. The
  #    child keeps /usr/bin:/bin (it needs `tr`, `sed`, `dirname`) but gets a
  #    shim dir first on PATH and every version-manager root pointed at a
  #    directory that does not exist. If a system Node of the declared major is
  #    sitting in /usr/bin or /bin this arm cannot be set up, and it says so
  #    rather than reporting a pass it did not measure.
  sysnode="$(PATH=/usr/bin:/bin command -v node 2>/dev/null || true)"
  sysmajor=""
  if [ -n "$sysnode" ]; then sysmajor="$(major_of "$sysnode")"; fi
  if [ "$sysmajor" = "$want" ]; then
    echo "  skip — $sysnode is major $want, so a no-matching-Node environment cannot be built here" >&2
  else
    shim="$(mktemp -d)"
    out="$(env -u NODE_BIN PATH="$shim:/usr/bin:/bin" \
             CONSOLE_HARNESS_ROOT="$ROOT" \
             CONSOLE_HARNESS_NVM_DIR=/nonexistent-nvm \
             CONSOLE_HARNESS_FNM_DIR=/nonexistent-fnm \
             CONSOLE_HARNESS_VOLTA_HOME=/nonexistent-volta \
             CONSOLE_HARNESS_ASDF_DIR=/nonexistent-asdf \
             sh "$self" --resolve 2>&1)"
    rc=$?
    rmdir "$shim" 2>/dev/null || true
    if [ "$rc" = "2" ]; then ok "no matching Node -> exit 2"; else bad "no matching Node -> expected exit 2, got $rc"; fi
    case "$out" in
      *"REFUSED"*"no Node major $want found"*) ok "…and the refusal NAMES the declared major ($want)" ;;
      *) bad "…refusal did not name the declared major. Got: $out" ;;
    esac
    case "$out" in
      *"looked in"*) ok "…and lists where it looked" ;;
      *) bad "…did not list where it looked. Got: $out" ;;
    esac
  fi

  # 2. A NODE_BIN that is not an executable is refused, named.
  out="$(NODE_BIN=/nonexistent/node sh "$self" --resolve 2>&1)"
  rc=$?
  if [ "$rc" = "2" ]; then ok "unusable NODE_BIN -> exit 2"; else bad "unusable NODE_BIN -> expected exit 2, got $rc"; fi
  case "$out" in
    *"REFUSED"*NODE_BIN*) ok "…and the refusal names NODE_BIN" ;;
    *) bad "…refusal did not name NODE_BIN. Got: $out" ;;
  esac

  # 3. THE BANNER IS MEASURED — the arm the prototype failed. Hand the script a
  #    node through NODE_BIN and require the banner to state the major that
  #    binary really reports, not the declared one.
  any="${CONSOLE_HARNESS_SELFTEST_NODE:-$(command -v node 2>/dev/null || true)}"
  if [ -z "$any" ]; then
    echo "  skip — no node on PATH, cannot exercise the banner arm" >&2
  else
    anymajor="$(major_of "$any")"
    out="$(NODE_BIN="$any" sh "$self" --resolve 2>&1)"
    case "$out" in
      *"running Node $anymajor "*"$any"*) ok "banner reports the RESOLVED binary's measured major ($anymajor)" ;;
      *) bad "banner did not report the measured major $anymajor. Got: $out" ;;
    esac
    if [ "$anymajor" = "$want" ]; then
      case "$out" in
        *"matches $DECL_REL ($want)"*) ok "…and a matching override is stated as matching" ;;
        *) bad "…a matching override was not stated as matching. Got: $out" ;;
      esac
    else
      case "$out" in
        *MISMATCH*) ok "…and marks a wrong-major override MISMATCH" ;;
        *) bad "…did not mark the wrong-major override MISMATCH. Got: $out" ;;
      esac
      case "$out" in
        *"running Node $want "*) bad "…banner printed the DECLARED major as the running one — the prototype's bug" ;;
        *) ok "…and never prints the declared major as the running one" ;;
      esac
    fi
  fi

  echo "console-harness --selftest: $pass passed / $fail failed"
  if [ "$fail" -eq 0 ]; then exit 0; fi
  exit 1
}

mode="${1:---run}"
case "$mode" in
  --selftest) selftest ;;
  --resolve|--run) ;;
  *)
    echo "console-harness: unknown argument '$mode'" >&2
    echo "usage: $0 [--run|--resolve|--selftest]" >&2
    exit 2
    ;;
esac

want="$(read_declaration)"
node="$(resolve_node "$want")"
if [ -z "$node" ]; then
  echo "console-harness: REFUSED — no Node major $want found (declared by $DECL_REL)." >&2
  echo "console-harness: looked in —" >&2
  looked_in "$want"
  echo "console-harness: install it (e.g. \`nvm install $want\`) or set NODE_BIN to the binary." >&2
  echo "console-harness: refusing to run the harness on an undeclared runtime." >&2
  exit 2
fi

banner "$node" "$want"
if [ "$mode" = "--resolve" ]; then exit 0; fi

exec "$node" --test "$ROOT/$TEST_REL"
