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
# THE PIN CI WILL REFUSE ON IS DERIVED HERE, NEVER RETYPED
# --------------------------------------------------------
# .github/workflows/console-harness.yml carries an EXACT, TWO-SIDED pin on the
# tally `node --test cloud/priv/static/__app.test.mjs` reports. Until
# task-561ac06ea4ebb607 this script ran that same command and said NOTHING about
# the pin — so the documented local gate omitted the one arm CI refuses on.
# MEASURED 2026-09-20: four console PRs (#19497 +1 test, #19498 +1, #19518 +2,
# #19523 +1 net) each ran this script, each got `# fail 0`, each reported GREEN,
# and each reddened in CI on `console harness: ran 1496 test(s), the committed
# pin is 1495` alone. The builders were honest and the gate was honest; the SEAM
# between them was the defect.
#
# So the pin arm below READS the literal out of the workflow — the pin sentence
# every console pin prints IS the enumeration rule (the same predicate
# scripts/console-pins.sh uses), keyed to the line that names $TEST_REL — and
# reds when the measured tally differs, naming the pin, the tally, and the
# workflow's own "bump every N in this step" instruction. The number is never
# retyped here: one source of truth, and a workflow this script cannot read is a
# REFUSAL (exit 2), never a silent skip. A gate that falls back to not-checking
# is the fail-toward-green shape this whole wave exists to delete.
#
# WHAT THIS DOES NOT FIX — THE SERIALIZATION COST, STATED
# ------------------------------------------------------
# Test-adding console PRs STILL merge strictly serially. The pin is one exact
# integer in one line, so N branches that each grow the suite each want a
# different value there, and every one but the first must rebase onto the
# previous merge and re-earn it (1495 -> 1496 -> 1497 -> …). At a ~380-run CI
# queue that is hours of wall-clock per PR, decided by one integer. This change
# does not touch that: the owner's 2026-09-11 ruling is that the pins stay
# two-sided (a one-sided floor never reds on GROWTH, so the literal goes stale
# and someone else pays the re-earn later), and weakening the pin to buy
# parallelism would trade a known, cheap, mechanical chore for a silent hole.
# What this change buys is that the chore is discovered LOCALLY, in seconds, by
# the gate the builder already runs — instead of after a CI queue, on a PR that
# then has to be rebased anyway. `bash scripts/console-pins.sh --write` does the
# re-earn mechanically.
#
# HOW IT LOSES — the four ways, all intentional:
#   · NODE_BIN set to a binary of the wrong major -> the banner reports that
#     major, marks it MISMATCH, and the harness runs anyway so the in-file
#     self-check produces the authoritative red. An explicit override is
#     honoured, never silently corrected.
#   · NODE_BIN set to something that is not an executable -> exit 2, named.
#   · No candidate of the declared major anywhere -> exit 2 with a named
#     refusal that LISTS where it looked. It never falls back to the default
#     Node and calls that a pass.
#   · The measured tally differs from the workflow's pin -> exit 1, naming both
#     numbers. Two-sided, exactly as CI is: a GROWN suite reds (bump the pin in
#     this same PR) and a SHRUNK one reds (tests deleted), and the gutted shape
#     the pin exists for — a file that still LOADS but registers nothing, which
#     node reports as `# pass 1` — reds too. The parser is self-tested against
#     that exact TAP before the real measurement, so a pin arm that has gone
#     blind refuses instead of passing vacuously.
#
# NOTE for `scaffy run add-console-helper`: that command plants two tests and
# closes on `ASSERT CMD "sh scripts/console-harness.sh"`. Since this change that
# assert REDS until the pin is re-earned — which is correct, because the tree it
# just produced would red CI. Run `bash scripts/console-pins.sh --write`.
#
# USAGE
#   sh scripts/console-harness.sh              # resolve + run the harness
#   sh scripts/console-harness.sh --resolve    # print the resolved binary, run nothing
#   sh scripts/console-harness.sh --selftest   # prove it can lose
#   sh scripts/console-harness.sh --pin        # print the pin read from CI, run nothing
#
# EXIT: 0 harness green + tally == the CI pin · 1 harness red (incl. the runtime
#       self-check) or a tally the CI pin refuses ·
#       2 REFUSED to run (no declared runtime found / unusable NODE_BIN /
#       unreadable or malformed declaration / the workflow pin cannot be read).

# `set -u` only, deliberately. Every failure path in this script is handled by
# name through `refuse`, and `set -e` would turn the ordinary `[ -x "$c" ] &&
# printf` probes in `candidates` into silent early exits — a runner that dies
# without a verdict is the shape this whole wave exists to delete.
set -u

ROOT="${CONSOLE_HARNESS_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
DECL_REL="cloud/priv/static/__node-version"
TEST_REL="cloud/priv/static/__app.test.mjs"
# The workflow that OWNS the pin. Overridable only so the refusal proofs can
# point this at a fixture; nothing in the repo sets it.
WF_REL="${CONSOLE_HARNESS_WORKFLOW:-.github/workflows/console-harness.yml}"

# The field-wise `# pass N` tally, byte-identical to the workflow step's own awk
# (and to scripts/console-pins.sh's). `# tests N` counts skipped and todo
# entries too and would be a DIFFERENT, wrong number.
# shellcheck disable=SC2016  # an awk PROGRAM: `$2`/`$3` are awk fields, and
# must reach awk unexpanded. Byte-identical to the workflow step's own awk.
TALLY_AWK='NF == 3 && $2 == "pass" && $3 ~ /^[0-9]+$/ { s += $3 } END { print s + 0 }'

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

# The EXACT tally CI will refuse anything else on, read out of the workflow.
#
# THE ENUMERATION IS A PREDICATE, NOT A LINE NUMBER. Every console pin prints
# the same red sentence — `the committed pin is <N>` — and each one's sentence
# names the suite it guards. So the rule is "the pin sentence that names
# $TEST_REL", which survives steps being added, moved or renamed above it. It
# must match EXACTLY ONCE: zero matches means the predicate has gone blind (or
# the pin is gone) and two means this script cannot tell which pin is ours.
# Both are refusals, because an unreadable pin is indistinguishable from a
# satisfied one and the whole point of this arm is to stop saying green on
# something it did not measure.
read_pin() {
  case "$WF_REL" in
    /*) wf="$WF_REL" ;;
    *)  wf="$ROOT/$WF_REL" ;;
  esac
  [ -f "$wf" ] || refuse "no workflow at $WF_REL (root $ROOT); the CI pin is the one source of truth for the tally and this script will not call a run green without reading it"
  hits="$(grep -F -- "$TEST_REL" "$wf" | grep -E 'the committed pin is [0-9]+' || true)"
  n="$(printf '%s\n' "$hits" | grep -c . || true)"
  case "${n:-0}" in
    1) : ;;
    0) refuse "found no \`the committed pin is <N>\` sentence naming $TEST_REL in $WF_REL. Either that step is gone or its wording changed — update the predicate in read_pin() deliberately. An unreadable pin is not a passed pin." ;;
    *) refuse "found $n \`the committed pin is <N>\` sentences naming $TEST_REL in $WF_REL; this script cannot tell which one guards the harness. Fix the workflow or teach read_pin(), do not guess." ;;
  esac
  printf '%s\n' "$hits" | sed -n 's/.*the committed pin is \([0-9][0-9]*\).*/\1/p' | head -n 1
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
  # 6. the GitHub Actions runner tool cache (task-88edd0348e6f703d): where
  #    actions/setup-node installs, and where runner images pre-cache majors.
  #    Same layout on both arches; the caller still measures what it finds.
  tool_cache="${CONSOLE_HARNESS_TOOL_CACHE:-${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}}"
  for c in "$tool_cache"/node/"$want".*/x64/bin/node "$tool_cache"/node/"$want".*/arm64/bin/node; do
    [ -x "$c" ] && printf '%s\n' "$c"
  done
  # 7. homebrew's versioned formulae, both prefixes
  for c in /opt/homebrew/opt/node@"$want"/bin/node /usr/local/opt/node@"$want"/bin/node; do
    [ -x "$c" ] && printf '%s\n' "$c"
  done
  # 8. a plainly-named sibling on PATH (`node20`, `node22`)
  p="$(command -v "node$want" 2>/dev/null || true)"
  [ -n "$p" ] && printf '%s\n' "$p"
  return 0
}

looked_in() {
  want="$1"
  echo "  PATH node, \$NVM_DIR/versions/node/v$want.*, \$FNM_DIR/node-versions/v$want.*," >&2
  echo "  \$VOLTA_HOME/tools/image/node/$want.*, \$ASDF_DATA_DIR/installs/nodejs/$want.*," >&2
  echo "  \$RUNNER_TOOL_CACHE/node/$want.*/{x64,arm64}," >&2
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
             CONSOLE_HARNESS_TOOL_CACHE=/nonexistent-tool-cache \
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

  # 1b. THE RUNNER TOOL CACHE IS SEARCHED (task-88edd0348e6f703d). The same
  #     no-matching-Node environment as arm 1, except that a binary reporting the
  #     declared major sits ONLY under a fake RUNNER_TOOL_CACHE, laid out the way
  #     actions/setup-node lays it out. It must resolve, by that exact path. The
  #     stub answers `--version` and nothing else: --resolve never runs it further.
  if [ "$sysmajor" = "$want" ]; then
    echo "  skip — $sysnode is major $want, so the tool-cache arm cannot isolate its root here" >&2
  else
    shim="$(mktemp -d)"
    tc="$(mktemp -d)"
    stub="$tc/node/$want.99.0/x64/bin/node"
    mkdir -p "$(dirname "$stub")"
    printf '#!/bin/sh\necho v%s.99.0\n' "$want" > "$stub"
    chmod +x "$stub"
    out="$(env -u NODE_BIN -u RUNNER_TOOL_CACHE PATH="$shim:/usr/bin:/bin" \
             CONSOLE_HARNESS_ROOT="$ROOT" \
             CONSOLE_HARNESS_NVM_DIR=/nonexistent-nvm \
             CONSOLE_HARNESS_FNM_DIR=/nonexistent-fnm \
             CONSOLE_HARNESS_VOLTA_HOME=/nonexistent-volta \
             CONSOLE_HARNESS_ASDF_DIR=/nonexistent-asdf \
             CONSOLE_HARNESS_TOOL_CACHE="$tc" \
             sh "$self" --resolve 2>&1)"
    rc=$?
    rm -rf "$shim" "$tc"
    if [ "$rc" = "0" ]; then ok "a Node $want only under the runner tool cache -> resolves (exit 0)"; else bad "a Node $want only under the runner tool cache -> expected exit 0, got $rc. Got: $out"; fi
    case "$out" in
      *"running Node $want "*"$stub"*) ok "…and the banner names the tool-cache binary" ;;
      *) bad "…banner did not name the tool-cache binary $stub. Got: $out" ;;
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
  --pin) read_pin; exit 0 ;;
  --resolve|--run) ;;
  *)
    echo "console-harness: unknown argument '$mode'" >&2
    echo "usage: $0 [--run|--resolve|--pin|--selftest]" >&2
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

pin="$(read_pin)"

# THE PARSER IS SELF-TESTED BEFORE THE MEASUREMENT — the shape the workflow step
# uses, kept here so the local arm cannot go blind in a way CI would not. The
# known input is the exact TAP a GUTTED file emits: node counts the FILE as one
# passing test, `# pass 1`. Two things are asserted about it — that the awk
# still reads 1 back out of it (an unguarded $(NF-1) once printed EMPTY and
# turned every comparison after it into a no-op), and that 1 is not the pin,
# i.e. the pin is still capable of refusing a gutting.
gutted="$(printf '# tests 1\n# pass 1\n# fail 0\n' | awk "$TALLY_AWK")"
if [ "${gutted:-x}" != "1" ] || [ "$gutted" -eq "$pin" ]; then
  echo "console-harness: tally self-test FAILED — a gutted file's TAP parsed to '${gutted}' against pin $pin. This pin can no longer lose, so a green from it would mean nothing." >&2
  exit 1
fi

tap="$(mktemp "${TMPDIR:-/tmp}/console-harness-tap.XXXXXX")" || refuse "could not create a temp file to capture the TAP"
"$node" --test "$ROOT/$TEST_REL" > "$tap" 2>&1
rc=$?
cat "$tap"
tally="$(awk "$TALLY_AWK" "$tap")"
rm -f "$tap"

if [ "$rc" -ne 0 ]; then
  echo "console-harness: the harness itself is RED (node --test exited $rc). The ${pin}-test pin is not adjudicated on a red suite — a red run's \`# pass\` count is what happened to work, not the pin." >&2
  exit 1
fi

if [ "${tally:-0}" -ne "$pin" ]; then
  echo "console-harness: ran ${tally:-0} test(s), the committed pin is $pin — this pin is EXACT (two-sided) and CI WILL REFUSE THIS TREE. The pin is read from $WF_REL, not retyped here. If the tally is HIGHER you grew $TEST_REL: bump every $pin in that step (the one named \"…${pin}-test EXACT pin…\") in THIS SAME PR, or run \`bash scripts/console-pins.sh --write\` to re-earn it mechanically. If it is LOWER, tests were deleted, or a file that still LOADS but registers nothing reported itself as one passing test." >&2
  exit 1
fi

echo "console-harness: ${tally} tests, exact pin $pin (read from $WF_REL) — the pin re-earned; CI's pin arm will agree."
exit 0
