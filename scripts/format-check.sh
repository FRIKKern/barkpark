#!/usr/bin/env bash
# format-check.sh — `mix format --check-formatted`, but it tells you WHICH
# question it answered.
#
# ─────────────────────────────────────────────────────────────────────────────
#  WHY THIS EXISTS (format-gate-is-elixir-version-contaminated)
# ─────────────────────────────────────────────────────────────────────────────
#  The honest-gates law is that a gate must red for EXACTLY ONE REASON — the
#  thing it claims to measure. `mix format --check-formatted` reds for THREE,
#  and two of them are invisible:
#
#    1. FORMATTING            the thing it claims to measure.
#    2. ELIXIR VERSION        the 1.18.x and 1.19.x formatters disagree, and
#                             not marginally. MEASURED 2026-07-20 on this repo:
#                             under CI's then-1.18.1 exactly ONE file was
#                             unformatted; under a local 1.19.5, 97 were. The
#                             two toolchains agreed on ZERO files. Every "N
#                             unformatted files" figure ever quoted from a local
#                             run described a set CI never evaluated — the count
#                             was published as 1, corrected to 91, corrected to
#                             92, and all three were answers to the wrong
#                             question. THIS CAUSE DOES NOT GO AWAY NOW THAT THE
#                             GATE AND THE FLEET AGREE (2026-09-02: both 1.19.5)
#                             — it goes QUIET, and a quiet cause is exactly the
#                             one that comes back unannounced when either side
#                             moves. The check below still runs.
#    3. UNFETCHED DEPS        a checkout without `mix deps.get` fails with
#                             "Unknown dependency :ecto_sql given to
#                             :import_deps", which is INDISTINGUISHABLE from a
#                             format failure at the exit-code level. A mutation
#                             test run there measures the dep error, not
#                             formatting.
#    4. THE FORMATTER NEVER   MEASURED 2026-09-03 (task-5e7315f1231641b8): on
#       RAN AT ALL            the fleet's Macs `mix` is a compile-slot wrapper
#                             (~/.local/bin/mix) that REFUSES every `mix format`
#                             unless BP_ALLOW_FORMAT=1 — it prints "mix format
#                             is REFUSED on this box" and exits non-zero WITHOUT
#                             invoking a formatter. This script read that exit
#                             as the formatting verdict, so it printed
#                             "!! UNFORMATTED (exit 1) — a real verdict" for
#                             EVERY file, including files CI's Format job passes.
#                             A FAILED READ WAS BYTE-IDENTICAL TO A RED — the
#                             exact disease this file exists to cure, in this
#                             file. Cured below by exit 6: the verdict branch is
#                             now reachable only when `mix format
#                             --check-formatted` actually ran and returned 1.
#
#  All four exit non-zero and, until now, all four looked the same. This
#  script separates them by exit code and says which one it is, BEFORE it runs
#  the formatter — so a wrong-toolchain run refuses to produce a number rather
#  than silently producing the wrong one.
#
#  THE PIN IS NOT THE ENFORCEMENT. `.tool-versions` already pinned Elixir, and
#  it did not help: asdf is not installed on every machine, so `elixir` resolves
#  to whatever is on PATH (measured 2026-07-20: .tool-versions said
#  1.18.4-otp-27, PATH gave Homebrew's 1.19.5/OTP 28, CI ran 1.18.1/OTP 27 —
#  THREE numbers, none of them reconciled). A declaration nothing checks is a
#  comment. This script is the check.
#
#  WHICH NUMBER THE GATE SHOULD BE (orchestrator ruling 2026-09-02,
#  task-9a08c27d897f38e6). The format gate now pins 1.19.5 — THE FORMATTER
#  DEVELOPERS AND AGENTS ACTUALLY RUN, measured on every box — because the
#  question this instrument answers is "is the tree formatted the way the people
#  who format it format it?", and no other answer is stable: `.tool-versions`
#  has asked for 1.18.4-otp-27 for months and the fleet has never once honoured
#  it, so each local `mix format` re-reddened the gate and each gate-shaped
#  repair was undone by the next local format. A treadmill, not a backlog.
#  `.tool-versions` deliberately did NOT move with it: it is production's
#  declaration (release-artifact.yml builds the prebuilt from it,
#  deploy/azure-base-install.sh pins every box's asdf to it), and the elixir.yml
#  mix-test / mix-prod-compile matrices are production's gates. So the PIN
#  DISAGREES warning below is now EXPECTED, and says so — two numbers, each
#  owned, rather than three unowned ones.
#
#  ONE SOURCE OF TRUTH FOR THE EXPECTED VERSION: it is READ OUT of
#  .github/workflows/elixir.yml's format job matrix, never restated here. A
#  second declaration is a second thing to drift, and drift between the pin and
#  the gate is the defect this file exists to stop.
#
# ─────────────────────────────────────────────────────────────────────────────
#  USAGE
# ─────────────────────────────────────────────────────────────────────────────
#    bash scripts/format-check.sh              # check; refuse if it cannot tell
#    bash scripts/format-check.sh --selftest   # prove each refusal can fire,
#                                              # and that both verdicts still get through
#
#  EXIT CODES — the whole point of the file:
#    0  formatted, under the right Elixir, with deps resolved
#    1  GENUINELY UNFORMATTED — the only code that is a claim about the code
#    3  WRONG ELIXIR — no claim made about formatting
#    4  DEPS NOT FETCHED — no claim made about formatting
#    5  the expected version could not be read out of the workflow
#    6  THE FORMATTER DID NOT RUN — no `mix` on PATH, a wrapper REFUSED the
#       invocation (the box's compile-slot shim does exactly this), or the
#       formatter exited with a code that is neither 0 nor 1. The wrapper's own
#       words are quoted back. No claim made about formatting.
#
#  Codes 3/4/5/6 are REFUSALS, not verdicts, and they say so in words. Nothing
#  downstream may read them as "the tree is unformatted". THE INVARIANT: exit 1
#  is emitted only when `mix format --check-formatted` RAN and returned 1.
set -uo pipefail

ROOT="${FORMAT_CHECK_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WORKFLOW="${FORMAT_CHECK_WORKFLOW:-$ROOT/.github/workflows/elixir.yml}"
API_DIR="${FORMAT_CHECK_API_DIR:-$ROOT/api}"

say() { printf '%s\n' "$*"; }

# ── the expected version, read out of the gate that will judge you ───────────
# Scoped to the `format:` job so a matrix elsewhere in the file cannot answer
# for it. If the shape ever changes, this REFUSES (exit 5) rather than guessing
# — a wrong expectation would be worse than none, because it would red people
# who are on the correct toolchain.
read_expected() {
  awk '
    /^  format:/            { in_job = 1; next }
    in_job && /^  [a-z_-]+:/ { in_job = 0 }
    in_job && /elixir: \[/  { if (match($0, /"[0-9][^"]*"/)) { print substr($0, RSTART+1, RLENGTH-2); exit } }
  ' "$1" 2>/dev/null
}

if [ "${1:-}" != "--selftest" ]; then
  if [ ! -f "$WORKFLOW" ]; then
    say "!! FORMAT CHECK REFUSED (exit 5): no workflow at $WORKFLOW, so the expected Elixir version cannot be read."
    say "   NO CLAIM is being made about formatting."
    exit 5
  fi
  EXPECTED="$(read_expected "$WORKFLOW")"
  if [ -z "$EXPECTED" ]; then
    say "!! FORMAT CHECK REFUSED (exit 5): could not read the format job's pinned elixir version out of $WORKFLOW."
    say "   The job's matrix shape changed. Fix this reader rather than guessing a version —"
    say "   a wrong expectation reds people who are on the CORRECT toolchain."
    say "   NO CLAIM is being made about formatting."
    exit 5
  fi

  RUNNING="$(elixir --version 2>/dev/null | sed -n 's/^Elixir \([0-9][0-9.]*\).*/\1/p' | head -1)"
  if [ -z "$RUNNING" ]; then
    say "!! FORMAT CHECK REFUSED (exit 3): no \`elixir\` on PATH, so no formatter version could be established."
    say "   NO CLAIM is being made about formatting."
    exit 3
  fi

  say ">> formatter   Elixir $RUNNING  (CI's format gate pins $EXPECTED, read from ${WORKFLOW#$ROOT/})"

  # THE OTHER NUMBER, surfaced rather than silently tolerated. `.tool-versions`
  # is what a developer running asdf/mise will actually get, and it is a
  # SEPARATE declaration from the gate's matrix — so it can disagree with the
  # thing that will judge them, and on this repo it does (pin 1.18.4-otp-27 vs
  # format gate 1.19.5).
  #
  # SINCE 2026-09-02 THAT DISAGREEMENT IS DELIBERATE, and the note says so
  # rather than pretending it is a fresh defect: the two declarations answer
  # different questions. `.tool-versions` is PRODUCTION's toolchain (the release
  # artifact and every box's asdf read it, as do the mix-test / mix-prod-compile
  # matrices at 1.18.1); this gate's matrix is THE FORMATTER, pinned to what the
  # fleet runs so that a local `mix format` and the gate reach the same verdict.
  # Still a WARNING and never a refusal: someone on the pin will be refused by
  # the version check below, with reasons, and that is the honest outcome.
  if [ -f "$ROOT/.tool-versions" ]; then
    PINNED="$(sed -n 's/^elixir[[:space:]]\{1,\}\([0-9][0-9.]*\).*/\1/p' "$ROOT/.tool-versions" | head -1)"
    if [ -n "$PINNED" ] && [ "$PINNED" != "$EXPECTED" ]; then
      say "!! PIN DISAGREES (expected — two owned numbers, not one unowned one):"
      say "     .tool-versions          elixir $PINNED   <- PRODUCTION's toolchain"
      say "     format gate matrix      elixir $EXPECTED   <- THE FORMATTER the fleet runs"
      say "   Deliberate since 2026-09-02: .tool-versions is read by release-artifact.yml,"
      say "   deploy/azure-base-install.sh and the mix-test/mix-prod-compile matrices, so it"
      say "   does NOT move with the format gate. Format under $EXPECTED. Neither pin is stale;"
      say "   moving either one to 'agree' would break the other's owner."
      say "   THIRD DECLARATION, OWNER-SIDE (outside this repo, not fixable from here):"
      say "   ~/.local/bin/mix — the fleet's compile-slot shim — hard-codes 1.18.4 at line 6"
      say "   (comment) and line 12 (the refusal text it prints). That text predates the"
      say "   2026-09-02 bump and now names the wrong CI pin; the shim's REFUSAL is still"
      say "   honoured here, its version prose is not read. Owner: the orchestrator."
    fi
  fi

  if [ "$RUNNING" != "$EXPECTED" ]; then
    say ""
    say "!! FORMAT CHECK REFUSED (exit 3): WRONG ELIXIR — this is a REFUSAL, not a verdict."
    say "   running:  Elixir $RUNNING"
    say "   the gate: Elixir $EXPECTED"
    say ""
    say "   The 1.18 and 1.19 formatters DISAGREE, and not marginally. Measured on this"
    say "   repo 2026-07-20: under 1.18.1 exactly ONE file was unformatted; under 1.19.5,"
    say "   97 were; the two sets overlapped in ZERO files. So any number produced here"
    say "   would describe a population the gate never evaluates — which is exactly how"
    say "   this repo published '1 file', then '91', then '92', all of them wrong."
    say ""
    say "   Do NOT run \`mix format\` to 'fix' this. Reformatting under $RUNNING rewrites"
    say "   files the gate considers CLEAN and will red the gate that is currently green."
    say ""
    say "   Get onto Elixir $EXPECTED and re-run. NOTE: since 2026-09-02 the format gate"
    say "   pins the formatter THE FLEET RUNS, which is NOT what .tool-versions declares"
    say "   (that one is production's, and mix-test/mix-prod-compile are its gates). So"
    say "   asdf/mise honouring .tool-versions will NOT get you to $EXPECTED — install"
    say "   $EXPECTED explicitly, or use whatever puts it on PATH."
    say "   NO CLAIM is being made about formatting."
    exit 3
  fi

  if [ ! -d "$API_DIR/deps" ] || [ -z "$(ls -A "$API_DIR/deps" 2>/dev/null)" ]; then
    say ""
    say "!! FORMAT CHECK REFUSED (exit 4): DEPS NOT FETCHED — this is a REFUSAL, not a verdict."
    say "   $API_DIR/deps is missing or empty."
    say ""
    say "   .formatter.exs uses \`import_deps\`, so the formatter needs deps to even parse its"
    say "   own config. Without them it dies with 'Unknown dependency :ecto_sql given to"
    say "   :import_deps' and a NON-ZERO exit that is indistinguishable from unformatted code."
    say "   A mutation test run in this state measures the dep error, not formatting."
    say ""
    say "   Run: (cd $API_DIR && mix deps.get)"
    say "   NO CLAIM is being made about formatting."
    exit 4
  fi

  say ">> deps        resolved in ${API_DIR#$ROOT/}/deps"

  if ! command -v mix >/dev/null 2>&1; then
    say ""
    say "!! CANNOT READ FORMATTING (exit 6): no \`mix\` on PATH, so the formatter never ran."
    say "   NO CLAIM is being made about formatting."
    exit 6
  fi

  # THE BOX SHIM, AND WHY THIS SCRIPT MAY OVERRIDE IT. ~/.local/bin/mix refuses
  # `mix format` unless BP_ALLOW_FORMAT=1, because a format under the WRONG
  # Elixir re-reds the gate. That guard is right and this script has already
  # satisfied it by hand, more precisely than the shim can: RUNNING == EXPECTED
  # was proved above against the gate's own matrix, and --check-formatted writes
  # nothing. So the export below is the shim's condition being MET, not bypassed
  # — and it is done HERE rather than by the caller, so that every lane gets an
  # honest read with the plain `bash scripts/format-check.sh` the ruling names.
  # A caller must never need BP_ALLOW_FORMAT=1 to get a verdict out of this file.
  out="$(cd "$API_DIR" && BP_ALLOW_FORMAT=1 mix format --check-formatted 2>&1)"
  rc=$?

  # A REFUSAL IS NOT A VERDICT. Belt and braces: the exit code (only 0 and 1 are
  # verdicts) AND the wrapper's own vocabulary, because a future wrapper may
  # refuse with 1. Either signal routes to exit 6.
  refused=""
  case "$rc" in 0|1) ;; *) refused="exit code $rc is neither 0 nor 1" ;; esac
  if printf '%s' "$out" | grep -qE 'REFUSED|UNCHECKED'; then
    refused="the \`mix\` on PATH refused to run the formatter"
  fi
  if [ -n "$refused" ]; then
    say ""
    say "!! CANNOT READ FORMATTING (exit 6): $refused — the formatter DID NOT RUN."
    say "   This is a REFUSAL, not a verdict. It is NOT 'unformatted'."
    say "   What the \`mix\` on PATH ($(command -v mix)) said, verbatim:"
    printf '%s\n' "$out" | sed 's/^/     | /'
    say ""
    say "   \`mix format --check-formatted\` never produced an answer, so there is nothing to"
    say "   report about this tree. Do NOT reformat anything on the strength of this run."
    say "   NO CLAIM is being made about formatting."
    exit 6
  fi

  say ""
  if [ "$rc" -eq 0 ]; then
    say "$out"
    say "FORMAT OK — the tree is formatted under Elixir $RUNNING, which is the version the gate uses."
    exit 0
  fi
  say "$out"
  say ""
  say "!! UNFORMATTED (exit 1) — a real verdict, under the RIGHT Elixir ($RUNNING == the gate's $EXPECTED)"
  say "   with deps resolved, so it is neither a version disagreement nor an import_deps error,"
  say "   and the formatter RAN (exit 1 from \`mix format --check-formatted\` itself)."
  say "   Fix with: (cd $API_DIR && mix format)"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
#  --selftest: PROVE EACH REFUSAL CAN FIRE
# ─────────────────────────────────────────────────────────────────────────────
#  A guard that separates three causes is worthless if it cannot demonstrate the
#  separation. Each case below drives the script into one state and asserts BOTH
#  the exit code AND that the message names that cause and no other — because
#  the failure this file exists to prevent is precisely a refusal being read as
#  a verdict.
#
#  It drives temp trees rather than the real one, so it is safe to run anywhere
#  and needs neither a toolchain swap nor a deps fetch.
fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

check() { # name expected_rc must_match must_not_match rc output
  local name="$1" want="$2" yes="$3" no="$4" rc="$5" out="$6"
  if [ "$rc" -ne "$want" ]; then
    say "  FAIL  $name — expected exit $want, got $rc"; fails=$((fails + 1)); return
  fi
  if ! printf '%s' "$out" | grep -q "$yes"; then
    say "  FAIL  $name — exit $rc was right but the message never says '$yes'"; fails=$((fails + 1)); return
  fi
  if [ -n "$no" ] && printf '%s' "$out" | grep -q "$no"; then
    say "  FAIL  $name — the message ALSO says '$no', so the causes are not separated"; fails=$((fails + 1)); return
  fi
  say "  ok    $name (exit $rc, names '$yes')"
}

SELF="${BASH_SOURCE[0]}"
say "=== format-check selftest: every refusal must be able to fire, and name itself ==="

# 1. UNREADABLE EXPECTATION — no workflow at all.
mkdir -p "$tmp/no-wf/api/deps" && : > "$tmp/no-wf/api/deps/keep"
out="$(FORMAT_CHECK_ROOT="$tmp/no-wf" FORMAT_CHECK_WORKFLOW="$tmp/no-wf/nope.yml" bash "$SELF" 2>&1)"; rc=$?
check "a missing workflow REFUSES rather than guessing a version" 5 "exit 5" "UNFORMATTED" "$rc" "$out"

# 2. UNREADABLE EXPECTATION — a workflow whose format job has no matrix.
mkdir -p "$tmp/bad-wf/api/deps" && : > "$tmp/bad-wf/api/deps/keep"
mkdir -p "$tmp/bad-wf/.github/workflows"
printf 'jobs:\n  format:\n    name: Format\n  other:\n    elixir: ["9.9.9"]\n' > "$tmp/bad-wf/.github/workflows/elixir.yml"
out="$(FORMAT_CHECK_ROOT="$tmp/bad-wf" FORMAT_CHECK_WORKFLOW="$tmp/bad-wf/.github/workflows/elixir.yml" bash "$SELF" 2>&1)"; rc=$?
check "a matrix in a DIFFERENT job must not answer for the format job" 5 "exit 5" "UNFORMATTED" "$rc" "$out"

# 3. WRONG ELIXIR — pin an expectation no toolchain satisfies.
mkdir -p "$tmp/wrong/api/deps" && : > "$tmp/wrong/api/deps/keep"
mkdir -p "$tmp/wrong/.github/workflows"
printf 'jobs:\n  format:\n    strategy:\n      matrix:\n        elixir: ["0.0.1"]\n' > "$tmp/wrong/.github/workflows/elixir.yml"
out="$(FORMAT_CHECK_ROOT="$tmp/wrong" FORMAT_CHECK_WORKFLOW="$tmp/wrong/.github/workflows/elixir.yml" bash "$SELF" 2>&1)"; rc=$?
check "a version mismatch REFUSES LOUDLY and is not reported as unformatted" 3 "WRONG ELIXIR" "UNFORMATTED" "$rc" "$out"
check "and it says NO CLAIM is being made, so nothing downstream reads it as a verdict" 3 "NO CLAIM" "" "$rc" "$out"
check "and it forbids the reflex 'fix' that would red a currently-green gate" 3 "Do NOT run" "" "$rc" "$out"

# 4. DEPS NOT FETCHED — expectation matches the running toolchain, deps empty.
running_probe="$(elixir --version 2>/dev/null | sed -n 's/^Elixir \([0-9][0-9.]*\).*/\1/p' | head -1)"
running="$running_probe"
if [ -n "$running" ]; then
  mkdir -p "$tmp/nodeps/api" "$tmp/nodeps/.github/workflows"
  printf 'jobs:\n  format:\n    strategy:\n      matrix:\n        elixir: ["%s"]\n' "$running" > "$tmp/nodeps/.github/workflows/elixir.yml"
  out="$(FORMAT_CHECK_ROOT="$tmp/nodeps" FORMAT_CHECK_WORKFLOW="$tmp/nodeps/.github/workflows/elixir.yml" bash "$SELF" 2>&1)"; rc=$?
  check "unfetched deps REFUSE as themselves, not as a format failure" 4 "DEPS NOT FETCHED" "UNFORMATTED" "$rc" "$out"
  check "and the import_deps trap is named so the next reader does not re-derive it" 4 "import_deps" "" "$rc" "$out"
else
  say "  skip  deps-refusal case — no elixir on PATH to match an expectation against"
fi

# 5. A WRAPPER REFUSAL IS NOT A VERDICT — the regression this file shipped with
#    until 2026-09-03. A fake `mix` speaks the box shim's exact refusal (exit 2,
#    "REFUSED"/"UNCHECKED", no formatter invoked) with everything else correct:
#    right Elixir, deps present. Before the fix this printed "!! UNFORMATTED
#    (exit 1) — a real verdict". It must now print CANNOT READ and exit 6, and
#    must NOT contain the word UNFORMATTED anywhere.
if [ -n "$running_probe" ]; then
  mkdir -p "$tmp/refuse/api/deps" "$tmp/refuse/.github/workflows" "$tmp/refuse/bin"
  : > "$tmp/refuse/api/deps/keep"
  printf 'jobs:\n  format:\n    strategy:\n      matrix:\n        elixir: ["%s"]\n' "$running_probe" \
    > "$tmp/refuse/.github/workflows/elixir.yml"
  cat > "$tmp/refuse/bin/mix" <<'FAKE'
#!/usr/bin/env bash
echo "mix format is REFUSED on this box: local Elixir 1.19.5 != the 1.18.4 that CI and prod use." >&2
echo "If you truly must: BP_ALLOW_FORMAT=1 mix format <file>" >&2
echo "UNCHECKED: this refusal is exit 2 — a toolchain refusal, never a formatting verdict." >&2
exit 2
FAKE
  chmod +x "$tmp/refuse/bin/mix"
  out="$(PATH="$tmp/refuse/bin:$PATH" FORMAT_CHECK_ROOT="$tmp/refuse" \
    FORMAT_CHECK_WORKFLOW="$tmp/refuse/.github/workflows/elixir.yml" bash "$SELF" 2>&1)"; rc=$?
  check "a wrapper REFUSAL refuses as itself and is NEVER reported as unformatted" 6 "CANNOT READ" "UNFORMATTED" "$rc" "$out"
  check "and it quotes the wrapper's own words so the reader can see WHO refused" 6 "REFUSED on this box" "" "$rc" "$out"
  check "and it says NO CLAIM, so nothing downstream reads exit 6 as a verdict" 6 "NO CLAIM" "" "$rc" "$out"
else
  say "  skip  wrapper-refusal case — no elixir on PATH to pin an expectation to"
fi

# 6. THE VERDICTS THEMSELVES, THROUGH THE PATH THE FLEET RUNS. The refusal
#    detector above is only safe if the two real answers still get through: a
#    formatted tree must exit 0 and an unformatted one must exit 1, with the
#    CALLER SETTING NOTHING (no BP_ALLOW_FORMAT — the script satisfies the
#    shim's condition itself, having already proved RUNNING == EXPECTED).
#    Uses the REAL toolchain when one is on PATH, so the verdicts are the
#    formatter's own and not a mock's opinion; skips otherwise.
if [ -n "$running_probe" ] && command -v mix >/dev/null 2>&1; then
  for kind in ok bad; do
    d="$tmp/verdict-$kind"
    mkdir -p "$d/api/deps" "$d/.github/workflows"; : > "$d/api/deps/keep"
    printf 'jobs:\n  format:\n    strategy:\n      matrix:\n        elixir: ["%s"]\n' "$running_probe" \
      > "$d/.github/workflows/elixir.yml"
    printf '[inputs: ["*.ex"]]\n' > "$d/api/.formatter.exs"
    if [ "$kind" = ok ]; then
      printf 'defmodule A do\n  def a, do: :ok\nend\n' > "$d/api/a.ex"
    else
      printf 'defmodule B do\n      def b,   do:   :ok\nend\n' > "$d/api/b.ex"
    fi
  done
  out="$(env -u BP_ALLOW_FORMAT FORMAT_CHECK_ROOT="$tmp/verdict-ok" \
    FORMAT_CHECK_WORKFLOW="$tmp/verdict-ok/.github/workflows/elixir.yml" bash "$SELF" 2>&1)"; rc=$?
  check "a FORMATTED tree still passes with the caller setting no BP_ALLOW_FORMAT" 0 "FORMAT OK" "CANNOT READ" "$rc" "$out"
  out="$(env -u BP_ALLOW_FORMAT FORMAT_CHECK_ROOT="$tmp/verdict-bad" \
    FORMAT_CHECK_WORKFLOW="$tmp/verdict-bad/.github/workflows/elixir.yml" bash "$SELF" 2>&1)"; rc=$?
  check "an UNFORMATTED file still reds as exit 1, and not as a refusal" 1 "UNFORMATTED" "CANNOT READ" "$rc" "$out"
  check "and the red names the file the formatter objected to" 1 "b.ex" "" "$rc" "$out"
else
  say "  skip  verdict cases — no elixir/mix on PATH to produce a real formatter verdict"
fi

# 7. THE READER ACTUALLY READS THE REAL WORKFLOW. If this ever returns empty on
#    the committed file, every case above is testing a straw man.
if [ -f "$WORKFLOW" ]; then
  real="$(read_expected "$WORKFLOW")"
  if [ -n "$real" ]; then
    say "  ok    the reader resolves the REAL workflow's pin: Elixir $real"
  else
    say "  FAIL  the reader returns EMPTY on the committed $WORKFLOW — every case above is a straw man"
    fails=$((fails + 1))
  fi
else
  say "  skip  real-workflow read — $WORKFLOW not present"
fi

say ""
if [ "$fails" -eq 0 ]; then
  say "SELFTEST OK — each cause refuses with its own exit code and names only itself."
  exit 0
fi
say "SELFTEST FAILED — $fails case(s) did not separate their cause." >&2
exit 1
