#!/usr/bin/env bash
# pds-blind-spot-check.sh — the tripwire that turns PDS-D633's last clause from a
# discipline into a mechanism.
#
# WHAT PDS-D633 ASKS FOR, AND WHY PROSE COULD NOT DELIVER IT
# -----------------------------------------------------------------------------
# D633 ends: "Every number this epic prints from a meter must carry the
# blind-spot sentence in the instrument's own @moduledoc AND its printed output,
# not in prose a copy-paste can drop." The wave-43 verifier then named the risk
# in its OWN finding: that instruction is a DISCIPLINE, not a mechanism — adopt
# it as prose and wave 44 restates it, which is the same failure mode the clause
# is about. This file is the mechanism. It reds when an instrument meters a
# duration or a CPU figure and does not carry the sentence to its output.
#
# THE POPULATION, AND ITS BOUNDARY, STATED (so a reader can disagree with it)
# -----------------------------------------------------------------------------
# SCANNED: scripts/pds-*.sh, scripts/pds-*.exs, tooling/pds/*.mjs.
# OBLIGED: those of them that hold at least one METER LINE — a live (non-comment)
#   call to a clock or CPU counter: `date +%s`, $EPOCHREALTIME, /usr/bin/time,
#   bash's `times` builtin, :erlang.statistics(:runtime|:wall_clock), :timer.tc,
#   System.monotonic_time, Date.now(), performance.now(), process.hrtime, or
#   Process.info(_, :reductions).
# NOT OBLIGED, ON PURPOSE: a printed duration the instrument did not meter — a
#   remote box's `uptime_seconds` read out of a JSON body, a configured poll
#   INTERVAL, a grace window in hours. D633 is a finding about METERS, and a
#   figure that came off the wire has a different provenance problem. Widening
#   the rule to every integer with an `s` after it would flag ~40 lines that no
#   meter produced and teach the next reader to wave the check through, which is
#   how a tripwire that grows stops discriminating.
# COMMENT LINES ARE NOT METER LINES. Otherwise this file — which names every
#   meter shape in the paragraph above — would be its own top offender.
# A LINE THAT QUOTES THE SENTENCE IS NOT A METER LINE. The sentence names
#   `:erlang.statistics(:runtime)` by construction, so without this exclusion the
#   check would fire on every instrument at the exact line where it OBEYS.
# THE MECHANISM ITSELF IS EXEMPT, structurally and by name, not by a list anyone
#   can append to: every file whose basename begins `blind-spot`/`pds-blind-spot`
#   — the shell constant, the JS constant, and this check — carries the sentence
#   and the meter vocabulary as DATA. They meter nothing and print no figure.
#   Three files today, and a NAMING RULE rather than a roster is what keeps that
#   from growing into a waiver list.
#
# WHAT IS CHECKED, PER OBLIGED INSTRUMENT
# -----------------------------------------------------------------------------
#   (1) PLACEMENT IN ITS OWN SOURCE. A `PDS-BLIND-SPOT-METER:` comment within
#       $WINDOW lines above a meter line, saying which placement this meter is
#       and why. The charter is not the place for this: whoever edits the
#       measuring call is reading the source, not the charter.
#   (2) THE SENTENCE ON ITS OWN OUTPUT PATH. The file calls the shared emitter
#       (`pds_blind_spot_note`, `blindSpotNote(`) or prints the constant itself;
#       or it declares `PDS-BLIND-SPOT-EMITTER: <path>` naming the file that
#       prints its figure, and THAT file emits. The declaration exists because
#       tooling/pds computes the figure in one module and prints it in another,
#       and demanding the sentence in a module that prints nothing would be a
#       rule satisfied by dead text.
#   (3) NO DRIFT. Any file in the scan set holding a copy of the sentence must
#       match `$PDS_BLIND_SPOT` byte for byte, once quoting and line-wrapping are
#       normalised away. Bash instruments SOURCE the constant and cannot drift;
#       the .exs and the .mjs hold a literal because neither can read a sibling
#       shell file where it runs (`--selftest` executes a mutated copy of the
#       census from a scratch dir), and THIS comparison is what makes those
#       copies safe.
#
# NON-VACUITY, BOTH WAYS. An empty scan set REDS (rc=1), and a scan set with zero
# metering instruments REDS: a check that finds nothing to check has gone blind,
# and the one thing worse than no tripwire is a green one that stopped looking.
#
# NEVER PIPE THIS SCRIPT'S VERDICT. `pds-blind-spot-check.sh | grep -q FAIL`
# reports grep's exit code, and under `set -o pipefail` a SIGPIPE'd writer can
# decide the pipeline's rc — the shape that once made a five-locale host report
# "no locale installed". Read to EOF, or match on a captured string.
#
# USAGE
#   scripts/pds-blind-spot-check.sh              # check the tree   (0 green / 1 red)
#   scripts/pds-blind-spot-check.sh --selftest   # prove it can go red (0 / 1)
#   scripts/pds-blind-spot-check.sh --list       # the population, one line each
#
# EXIT: 0 every obliged instrument holds · 1 a check failed, or the population
#       came out empty · 2 an unknown argument.
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/pds-blind-spot.sh
. "$SCRIPT_DIR/pds-blind-spot.sh"

# How far above a meter line the placement comment may sit. Generous on purpose:
# the comment belongs above the call with its reasoning, and PDS-D633's reasoning
# does not fit on one line.
WINDOW=24

# The meter shapes, as ONE regex used by both the census and the selftest, so the
# arm cannot drift from the rule it proves.
METER_RE='date \+%s|EPOCHREALTIME|/usr/bin/time|(^|[;&|])[[:space:]]*times[[:space:]]*("|'"'"'|;|$)|:erlang\.statistics\(:(runtime|wall_clock)\)|:timer\.tc|System\.monotonic_time|Date\.now\(\)|performance\.now\(\)|process\.hrtime|Process\.info\([^)]*:reductions'

# A line that QUOTES the blind-spot sentence is not a line that CALLS a meter.
# The sentence names `:erlang.statistics(:runtime)` by construction — that is the
# whole point of it — so without this, every instrument that obeys D633 would be
# flagged by the very sentence it prints, at the line where it prints it.
QUOTE_RE='is a VM-GLOBAL sum of BEAM scheduler|METER BLIND SPOT'

# Something the instrument PRINTS that carries a duration or CPU unit. Reported
# as evidence beside each obliged instrument; it is not itself the trigger.
FIGURE_RE='(ms|s|CPU|cpu|user|reductions)[^A-Za-z]*(\}|"|\)|$)'

say() { printf '%s\n' "$*"; }

# The sentence, normalised: quoting and line-wrapping removed so a literal split
# across `<>` (Elixir) or `+` (JS) compares equal to the one-line shell constant.
normalise() {
  sed 's/<>//g' | tr -d '"+' | tr -d '[:space:]'
}

CANON_NORM="$(printf '%s' "$PDS_BLIND_SPOT" | normalise)"

# Non-comment lines only. A file that NAMES a meter shape in prose is not
# metering anything, and this file would otherwise be its own worst offender.
meter_lines() {
  grep -nE "$METER_RE" "$1" 2>/dev/null |
    grep -vE '^[0-9]+:[[:space:]]*(#|//|\*)' |
    grep -vE "$QUOTE_RE" || true
}

# A LIVE call to the shared emitter, or the constant printed by name. COMMENT
# LINES DO NOT COUNT, and that is not a detail: found BY RUN, deleting every
# `pds_blind_spot_note` call from pds-pull-proof.sh left this check GREEN,
# because the file's own `# ... $PDS_BLIND_SPOT ...` source comment satisfied the
# match. A guard a comment can satisfy is a guard the next copy-paste walks past
# — the exact failure mode PDS-D633's last clause is about, reproduced inside the
# mechanism built to stop it. Arm "a COMMENT naming the constant does not satisfy
# the emission requirement" is that mutation, kept.
emits_sentence() {
  grep -nE 'pds_blind_spot_note|blindSpotNote\(|blind_spot_sentence|\$PDS_BLIND_SPOT|PDS_BLIND_SPOT[^_]' "$1" 2>/dev/null |
    grep -vcE '^[0-9]+:[[:space:]]*(#|//|\*)' || true
}

declared_emitter() {
  sed -n 's/.*PDS-BLIND-SPOT-EMITTER:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$1" 2>/dev/null | head -1
}

# THE MECHANISM'S OWN FILES, by name rather than by an appendable list: every
# file whose basename begins `blind-spot` or `pds-blind-spot` IS the constant or
# IS this check. They carry the sentence and the meter vocabulary as DATA; they
# meter nothing and print no figure of their own. Three files today, and the
# naming rule — not a roster — is what keeps it from growing into a waiver list.
is_mechanism() {
  case "$(basename "$1")" in
    blind-spot.* | pds-blind-spot.* | pds-blind-spot-check.*) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# THE CENSUS
# ---------------------------------------------------------------------------
run_check() {
  local root="${1:-$REPO_ROOT}"
  local list_only="${2:-}"
  local f rel scanned=0 obliged=0 fails=0 mlines first_meter placement_ok emit_n anchored_meter
  local em em_path figures placement_line lo

  say "PDS BLIND-SPOT CHECK (PDS-D633) — the sentence is a mechanism, not a discipline"
  say "root: $root"
  say ""

  local files=''
  for f in "$root"/scripts/pds-*.sh "$root"/scripts/pds-*.exs "$root"/tooling/pds/*.mjs; do
    [ -f "$f" ] || continue
    files="$files$f
"
  done

  if [ -z "$files" ]; then
    say "RED — the scan set is EMPTY. No scripts/pds-*.{sh,exs} and no tooling/pds/*.mjs"
    say "      were found under $root. A check with nothing to check is not a green;"
    say "      it is a blind instrument reporting success. Exit 1."
    return 1
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$root"/}"
    scanned=$((scanned + 1))

    # (3) DRIFT — asked of EVERY scanned file, obliged or not. A stale copy in a
    # file that no longer meters anything is still a second source of truth.
    if grep -q 'VM-GLOBAL sum of BEAM scheduler' "$f" 2>/dev/null; then
      if is_mechanism "$f"; then
        : # the canonical text itself
      else
        local got
        got="$(normalise <"$f")"
        case "$got" in
          *"$CANON_NORM"*) : ;;
          *)
            say "  FAIL  $rel — holds a copy of the blind-spot sentence that has DRIFTED from"
            say "        \$PDS_BLIND_SPOT in scripts/pds-blind-spot.sh. Two sources of truth for one"
            say "        sentence is the defect this check exists to refuse; re-source or re-copy it."
            fails=$((fails + 1))
            ;;
        esac
      fi
    fi

    is_mechanism "$f" && continue

    mlines="$(meter_lines "$f")"
    [ -n "$mlines" ] || continue
    obliged=$((obliged + 1))

    figures="$(grep -nE "$FIGURE_RE" "$f" 2>/dev/null | grep -cE 'printf|echo|say |info |ok |p\(|IO\.puts|console\.log|out\.push' || true)"
    first_meter="$(printf '%s' "$mlines" | head -1 | cut -d: -f1)"
    anchored_meter=''

    if [ -n "$list_only" ]; then
      say "  $rel"
      say "      meters at: $(printf '%s' "$mlines" | cut -d: -f1 | tr '\n' ' ')"
      say "      printed-figure candidates: $figures"
      continue
    fi

    # (1) PLACEMENT, in this file's own source, near a meter line.
    placement_ok=no
    while IFS= read -r placement_line; do
      [ -n "$placement_line" ] || continue
      lo="${placement_line%%:*}"
      local ml
      while IFS= read -r ml; do
        [ -n "$ml" ] || continue
        ml="${ml%%:*}"
        if [ "$lo" -le "$ml" ] && [ $((ml - lo)) -le "$WINDOW" ]; then
          placement_ok=yes
          [ -n "$anchored_meter" ] || anchored_meter="$ml"
        fi
      done <<EOF
$mlines
EOF
    done <<EOF
$(grep -n 'PDS-BLIND-SPOT-METER:' "$f" 2>/dev/null || true)
EOF

    if [ "$placement_ok" = 'no' ]; then
      say "  FAIL  $rel — meters at line $first_meter with NO 'PDS-BLIND-SPOT-METER:' comment"
      say "        within $WINDOW lines above it. PDS-D633's placement rule has to live beside the"
      say "        measuring call: whoever moves that call is reading this source, not the charter."
      fails=$((fails + 1))
    fi

    # (2) THE SENTENCE, on this instrument's own output path.
    emit_n="$(emits_sentence "$f")"
    em=''
    if [ "${emit_n:-0}" -eq 0 ]; then
      em_path="$(declared_emitter "$f")"
      if [ -n "$em_path" ] && [ -f "$root/$em_path" ] && [ "$(emits_sentence "$root/$em_path")" -gt 0 ]; then
        em=" (emitted by $em_path, as declared)"
      else
        say "  FAIL  $rel — meters at line $first_meter and never reaches the blind-spot sentence."
        say "        Source scripts/pds-blind-spot.sh and call pds_blind_spot_note beside the figure,"
        say "        or declare 'PDS-BLIND-SPOT-EMITTER: <path>' naming the file that prints it."
        fails=$((fails + 1))
        em=' (MISSING)'
      fi
    fi

    if [ "$placement_ok" = 'yes' ] && [ "${em}" != ' (MISSING)' ]; then
      say "  ok    $rel — meter at :${anchored_meter:-$first_meter}, placement stated, sentence on the output path$em"
    fi
  done <<EOF
$files
EOF

  say ""
  say "scanned $scanned file(s); $obliged carry a live meter."

  if [ -n "$list_only" ]; then
    return 0
  fi

  # NON-VACUITY, THE OTHER WAY. A scan set that yields zero metering instruments
  # means the meter regex has stopped matching the tree — a rename, a rewrite, a
  # typo in $METER_RE — and every arm below would pass on an empty population.
  if [ "$obliged" -eq 0 ]; then
    say "RED — ZERO metering instruments found in a non-empty scan set. Either every"
    say "      meter left the tree at once, or \$METER_RE no longer matches it. Both are"
    say "      reasons to red: a check with an empty population passes on nothing. Exit 1."
    return 1
  fi

  if [ "$fails" -gt 0 ]; then
    say "RED — $fails obligation(s) unmet across $obliged metering instrument(s). Exit 1."
    return 1
  fi
  say "GREEN — all $obliged metering instrument(s) carry the sentence and state their placement. Exit 0."
  return 0
}

# ---------------------------------------------------------------------------
# THE SELFTEST — the check must be shown able to go RED, on a tree it did not
# write, before its green means anything.
# ---------------------------------------------------------------------------
run_selftest() {
  local tmp pass=0 fail=0 out rc

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/pds-blind-spot-selftest.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  mkdir -p "$tmp/scripts" "$tmp/tooling/pds"
  cp "$SCRIPT_DIR/pds-blind-spot.sh" "$tmp/scripts/"
  cp "$0" "$tmp/scripts/"

  arm() {
    # $1 label · $2 wanted rc · $3 a substring the output must carry · $4 root
    set +e
    out="$(bash "$tmp/scripts/$SELF" --root "${4:-$tmp}" 2>&1)"
    rc=$?
    set -e
    local hit=no
    case "$out" in *"$3"*) hit=yes ;; esac
    if [ "$rc" = "$2" ] && [ "$hit" = 'yes' ]; then
      say "  PASS  $1 (rc=$rc)"
      pass=$((pass + 1))
    else
      say "  FAIL  $1 — rc=$rc (wanted $2), wanted substring: $3"
      say "$out" | sed 's/^/        /'
      fail=$((fail + 1))
    fi
  }

  say "PDS BLIND-SPOT CHECK — SELFTEST"
  say ""

  # ARM 1a — AN EMPTY SCAN SET REDS. The first of the two non-vacuity guards:
  # pointed at a tree that holds no pds instrument at all, the check must refuse,
  # not report success because it looked at nothing.
  mkdir -p "$tmp/nothing-here"
  arm "an EMPTY scan set reds instead of passing vacuously" 1 'the scan set is EMPTY' "$tmp/nothing-here"

  # ARM 1b — A SCAN SET WITH ZERO METERS REDS. The second guard, and the one that
  # catches the likelier failure: the files are all still there and $METER_RE has
  # quietly stopped matching any of them. At this point $tmp holds only the
  # mechanism's own two files, which are exempt by name — so the population is
  # legitimately zero, and a zero population is a red, not a green.
  arm "a scan set with ZERO metering instruments reds" 1 'ZERO metering instruments found'

  # ARM 2 — a compliant instrument passes. Everything below mutates THIS file, so
  # every red beneath is a red against a tree that was green a moment earlier.
  cat >"$tmp/scripts/pds-fx-good.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
D="$(cd -P -- "$(dirname -- "$0")" && pwd)"
. "$D/pds-blind-spot.sh"
# PDS-BLIND-SPOT-METER: date +%s, WALL CLOCK around the work in this shell — an
# OS clock outside every BEAM (PDS-D633 placement (a)); a latency, not a price.
t0="$(date +%s)"
t1="$(date +%s)"
printf 'took %ss\n' "$(( t1 - t0 ))"
pds_blind_spot_note "date +%s, WALL CLOCK in this shell" "took"
FIXTURE
  arm "a compliant instrument passes" 0 'ok    scripts/pds-fx-good.sh'

  # ARM 3 — THE HEADLINE. Delete the sentence from an instrument that still
  # meters and still prints its figure: the check must red.
  cp "$tmp/scripts/pds-fx-good.sh" "$tmp/scripts/pds-fx-mute.sh"
  grep -v 'pds_blind_spot_note' "$tmp/scripts/pds-fx-good.sh" >"$tmp/scripts/pds-fx-mute.sh.new"
  mv "$tmp/scripts/pds-fx-mute.sh.new" "$tmp/scripts/pds-fx-mute.sh"
  arm "an instrument that meters and prints but drops the sentence REDS" 1 'never reaches the blind-spot sentence'
  rm -f "$tmp/scripts/pds-fx-mute.sh"

  # ARM 4 — the placement rule deleted from the meter's own source reds, even
  # with the sentence still printing. Criterion (1) is separately falsifiable.
  grep -v 'PDS-BLIND-SPOT-METER' "$tmp/scripts/pds-fx-good.sh" >"$tmp/scripts/pds-fx-noplace.sh"
  arm "a meter with no placement comment beside it REDS" 1 "NO 'PDS-BLIND-SPOT-METER:' comment"
  rm -f "$tmp/scripts/pds-fx-noplace.sh"

  # ARM 5 — a DRIFTED copy of the sentence reds. One byte: 5.0x becomes 5.1x.
  {
    printf '#!/usr/bin/env bash\n'
    printf '# PDS-BLIND-SPOT-METER: date +%%s in this shell (fixture)\n'
    printf 't0="$(date +%%s)"\n'
    printf 'BLIND="%s"\n' "$(printf '%s' "$PDS_BLIND_SPOT" | sed 's/5\.0x/5.1x/')"
    printf 'printf "%%s\\n" "$BLIND"\n'
  } >"$tmp/scripts/pds-fx-drift.sh"
  arm "a one-byte DRIFTED copy of the sentence REDS" 1 'has DRIFTED from'
  rm -f "$tmp/scripts/pds-fx-drift.sh"

  # ARM 6 — the EMITTER declaration is honoured, and only when it is honest.
  cat >"$tmp/tooling/pds/fx-compute.mjs" <<'FIXTURE'
// PDS-BLIND-SPOT-METER: Date.now(), wall clock in this Node process (fixture).
// PDS-BLIND-SPOT-EMITTER: tooling/pds/fx-print.mjs
const started = Date.now();
export const ms = () => Date.now() - started;
FIXTURE
  cat >"$tmp/tooling/pds/fx-print.mjs" <<'FIXTURE'
import { blindSpotNote } from "./blind-spot.mjs";
export const render = (ms) => [`elapsed ${ms}ms`, ...blindSpotNote()];
FIXTURE
  arm "a declared EMITTER satisfies the obligation for the module that computes" 0 'as declared'

  # ARM 7 — and an emitter declaration pointing at a file that does NOT emit is
  # NOT a way out. A pointer is only worth what it points at.
  cat >"$tmp/tooling/pds/fx-print.mjs" <<'FIXTURE'
export const render = (ms) => [`elapsed ${ms}ms`];
FIXTURE
  arm "an EMITTER pointing at a file that does not emit REDS" 1 'never reaches the blind-spot sentence'
  rm -f "$tmp/tooling/pds/fx-compute.mjs" "$tmp/tooling/pds/fx-print.mjs"

  # ARM 8 — A COMMENT NAMING THE CONSTANT DOES NOT SATISFY THE OBLIGATION. This
  # arm exists because the check FAILED it on first run: with the emission scan
  # matching comment lines, deleting every emitter call from the real
  # pds-pull-proof.sh left the whole tree GREEN, since its own source comment
  # mentions $PDS_BLIND_SPOT. Kept as the mutation that caught it.
  {
    printf '#!/usr/bin/env bash\n'
    printf '# PDS-BLIND-SPOT-METER: date +%%s in this shell (fixture)\n'
    printf '# This file sources the constant for $PDS_BLIND_SPOT and calls\n'
    printf '# pds_blind_spot_note somewhere. Except it does not: this is a COMMENT.\n'
    printf 't0="$(date +%%s)"\n'
    printf 'printf "took %%ss\\n" "$t0"\n'
  } >"$tmp/scripts/pds-fx-commentonly.sh"
  arm "a COMMENT naming the constant does not satisfy the emission requirement" 1 'never reaches the blind-spot sentence'
  rm -f "$tmp/scripts/pds-fx-commentonly.sh"

  # ARM 9 — a file that meters ONLY in a comment is not obliged. Without this the
  # check would red on every file that DOCUMENTS a meter, this one included, and
  # a rule that fires on its own documentation is a rule people switch off.
  cat >"$tmp/scripts/pds-fx-prose.sh" <<'FIXTURE'
#!/usr/bin/env bash
# This file mentions date +%s and /usr/bin/time and Date.now() in prose only.
# It meters nothing and prints no figure.
echo hello
FIXTURE
  arm "a file naming a meter only in a COMMENT is not obliged" 0 'ok    scripts/pds-fx-good.sh'
  rm -f "$tmp/scripts/pds-fx-prose.sh"

  say ""
  say "SELFTEST: $pass PASS / $fail FAIL of $((pass + fail)) arms"
  if [ "$fail" -gt 0 ]; then
    say "SELFTEST RED — exit 1"
    return 1
  fi
  say "SELFTEST GREEN — exit 0"
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local root="$REPO_ROOT" mode='check'
  while [ $# -gt 0 ]; do
    case "$1" in
      --selftest) mode='selftest'; shift ;;
      --list) mode='list'; shift ;;
      --root) root="${2:-}"; shift 2 ;;
      --help | -h) sed -n '3,72p' "$0"; return 0 ;;
      *)
        printf '%s: unknown argument %s (accepted: --selftest --list --root DIR --help)\n' "$SELF" "$1" >&2
        printf '%s: a check that silently swallows a flag reports on a population nobody asked for.\n' "$SELF" >&2
        return 2
        ;;
    esac
  done
  case "$mode" in
    selftest) run_selftest ;;
    list) run_check "$root" list ;;
    *) run_check "$root" ;;
  esac
}

main "$@"
