#!/usr/bin/env bash
#
# console-pins.sh — re-derive EVERY console TAP pin by MEASURING, and rewrite
# the literals in place.
#
# WHY THIS EXISTS
# ---------------
# .github/workflows/console-harness.yml carries EXACT, TWO-SIDED pins: a
# literal that must equal the number of tests a named suite reports. The owner
# ruled on 2026-09-11 that they stay two-sided — a one-sided floor never reds on
# growth, so the literal goes stale and someone else pays the re-earn chore
# later. That ruling stands and NOTHING here weakens a pin: this script only
# ever sets a literal to a number it just measured.
#
# The cost the two-sided pin creates is not the pin, it is the CHORE. Three
# console branches bumping the same pin to three different numbers invalidate
# each other on every rebase, and a re-earn done by hand is a sequence of
# commands somebody has to remember correctly. One round produced four workers
# each hand-deriving a different subset, and one of them was handed 125 -> 126
# for a pin that was really 128 -> 129. This makes the chore mechanical.
#
# THE ENUMERATION IS A PREDICATE, NOT A LIST
# ------------------------------------------
# A pin announces itself by the sentence it prints when it reds. Every pin in
# the console lane prints
#
#     the committed pin is <N> — this pin is EXACT (two-sided)
#
# so that sentence IS the enumeration rule. This script scans the workflow for
# it and derives the pin set fresh on every run; a pin added tomorrow is picked
# up with no edit here, and a pin whose step is deleted stops being looked for.
# `--list` prints what the predicate found. `--selftest` proves the predicate
# can say YES and can say NO — the same shape the workflow's own derived-
# selection step uses on its own selection.
#
# THE MEASURING COMMAND IS EXTRACTED FROM THE WORKFLOW, NOT RESTATED HERE
# ----------------------------------------------------------------------
# For each pin step this takes the step's own `run:` body, truncates it at (and
# including) the `| tee /tmp/…` line that captures the TAP, and runs THAT. So
# the number is produced by the same shell CI runs, including each step's
# private setup (the seal-predicate step builds a network-recording curl shim
# first). A restatement here would be a second, drifting copy of the
# instrument — the exact defect this lane keeps finding in its own gates.
#
# THE RUNTIME IS RESOLVED, NEVER INHERITED
# ----------------------------------------
# cloud/priv/static/__node-version DECLARES the major. Developer boxes default
# to something else, and __app.test.mjs carries a self-check that reds BY NAME
# on the wrong major — so a bare `node --test` on such a box LIES. Two defences:
#   · the __app.test.mjs pin is measured through `scripts/console-harness.sh`,
#     which resolves the declared runtime and refuses if it cannot find one;
#   · every other extracted body runs with a shim dir first on PATH whose
#     `node` IS that same resolved binary, so `node --test` inside the body
#     means the declared major and nothing else.
#
# THE TALLY IS `# pass N`, NOT `# tests N`
# ----------------------------------------
# The workflow sums the TAP `# pass N` lines field-wise. `# tests N` counts
# skipped and todo entries too and would be a different, wrong number. This
# script uses the awk program EXTRACTED FROM THE STEP so the two cannot
# diverge, and refuses a step whose awk is not that one.
#
# ONLY FUNCTIONAL LITERALS ARE REWRITTEN
# --------------------------------------
# A pin comment's history sentences ("#17828's took it 119 -> 129", "PIN 1436 —
# bumped 2026-09-12 from 1431") are the record of what the count used to be and
# why. Rewriting those destroys the record. So the rewrite skips every comment
# line in the step and touches only four anchored slots:
#   `-ne N`   ·   `pin N` / `pin is N`   ·   `bump every N`   ·   `N-test`
# After a rewrite the file is RE-READ: a functional slot still holding the old
# number is a loud refusal, not a silent half-write, and any OTHER standalone
# occurrence of the old number on a non-comment line is reported as a NOTE for
# a human to look at.
#
# IT REFUSES RATHER THAN GUESSING
# -------------------------------
# No pin is ever computed by arithmetic on its previous value. If an instrument
# produces no `# pass` line at all — it crashed, it was pointed at something
# that is not a node:test suite, the runtime refused — this says so by name and
# exits 3. A silently-wrong pin is worse than no tool.
#
# USAGE
#   bash scripts/console-pins.sh --list        # what the predicate finds
#   bash scripts/console-pins.sh --check       # measure, report drift, exit 1
#   bash scripts/console-pins.sh --write       # measure and rewrite the literals
#   bash scripts/console-pins.sh --selftest    # prove the predicate can say NO
#   … --only <substring>   restrict to pin steps whose name matches
#   … --skip <substring>   exclude a pin step by name (repeatable). A SKIPPED
#                          pin is reported as not measured — it is never
#                          reported as clean.
#
# EXIT: 0 no drift (or written) · 1 drift found (--check) · 2 bad usage /
#       unreadable workflow / a pin step this script cannot interpret ·
#       3 REFUSED — an instrument produced no tally to read.

set -uo pipefail

ROOT="${CONSOLE_PINS_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
WF_REL="${CONSOLE_PINS_WORKFLOW:-.github/workflows/console-harness.yml}"
case "$WF_REL" in
  /*) WF="$WF_REL" ;;      # an absolute override, used by the refusal proofs
  *)  WF="$ROOT/$WF_REL" ;;
esac
HARNESS_REL="scripts/console-harness.sh"
TAB="$(printf '\t')"

# The field-wise `# pass N` tally the workflow uses. A step that sums anything
# else is measuring a different quantity and is refused rather than re-derived.
TALLY_AWK='NF == 3 && $2 == "pass" && $3 ~ /^[0-9]+$/ { s += $3 } END { print s + 0 }'

MODE=""
ONLY=""
SKIP=""

die2() { echo "console-pins: REFUSED — $*" >&2; exit 2; }
die3() { echo "console-pins: REFUSED — $*" >&2; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --list|--check|--write|--selftest)
      [ -n "$MODE" ] && die2 "two modes given ($MODE and $1); pick one"
      MODE="$1" ;;
    --only) shift; [ $# -gt 0 ] || die2 "--only needs a value"; ONLY="$1" ;;
    --only=*) ONLY="${1#--only=}" ;;
    --skip) shift; [ $# -gt 0 ] || die2 "--skip needs a value"; SKIP="$SKIP$TAB$1" ;;
    --skip=*) SKIP="$SKIP$TAB${1#--skip=}" ;;
    -h|--help) sed -n '/^# USAGE/,/^#       3 REFUSED/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die2 "unknown argument '$1' (want --list|--check|--write|--selftest [--only S])" ;;
  esac
  shift
done
[ -n "$MODE" ] || die2 "no mode given (want --list|--check|--write|--selftest)"
[ -f "$WF" ] || die2 "no workflow at $WF_REL (root $ROOT)"

# ── The runtime, resolved and MEASURED ───────────────────────────────────────
# console-harness.sh --resolve prints one banner naming the binary it would run
# and exits 2 when it cannot find the declared major. Both halves are used: the
# path is read out of the banner, and a non-zero exit is propagated as a
# refusal rather than papered over by falling back to `node`.
resolve_node() {
  out="$(sh "$ROOT/$HARNESS_REL" --resolve 2>&1)"; rc=$?
  if [ "$rc" != 0 ]; then
    echo "$out" >&2
    die3 "$HARNESS_REL could not resolve the declared runtime (exit $rc). Nothing measured."
  fi
  p="$(printf '%s\n' "$out" | sed -n 's/^console-harness: running Node .* from \(.*\) — .*$/\1/p' | head -n 1)"
  [ -n "$p" ] || die3 "could not read a node path out of the harness banner: $out"
  [ -x "$p" ] || die3 "the harness banner named '$p', which is not an executable"
  printf '%s\n' "$p"
}

# ── The enumeration ──────────────────────────────────────────────────────────
# One TSV row per pin: name_line, run_first, run_last, pin, step_name.
# A step starts at `- name:` at the step indent; its body is the indented block
# under `run: |`; it is a PIN step iff that body prints the red sentence.
enumerate() {
  awk '
    function flush() {
      if (nameline && runfirst && body ~ /the committed pin is [0-9]+/) {
        match(body, /the committed pin is [0-9]+/)
        s = substr(body, RSTART, RLENGTH); sub(/.* /, "", s)
        printf "%d\t%d\t%d\t%s\t%s\n", nameline, runfirst, runlast, s, stepname
      }
      nameline = 0; runfirst = 0; runlast = 0; body = ""; stepname = ""
    }
    /^      - name:/ {
      flush()
      nameline = NR; stepname = $0; sub(/^      - name: */, "", stepname)
      inrun = 0; next
    }
    /^        run: *\|/ { inrun = 1; runfirst = NR + 1; runlast = NR; next }
    {
      if (inrun) {
        if ($0 ~ /^          / || $0 ~ /^[ \t]*$/) { runlast = NR; body = body "\n" $0 }
        else inrun = 0
      }
    }
    END { flush() }
  ' "$1"
}

# The step body, dedented, truncated at the tee that captures the TAP.
extract_body() {
  sed -n "${1},${2}p" "$WF" | awk '
    { sub(/^          /, ""); print }
    /\| *tee \/tmp\// { exit }
  '
}

tee_path_of() {
  printf '%s\n' "$1" | sed -n 's/.*| *tee *\(\/tmp\/[^ ]*\).*/\1/p' | tail -n 1
}

# Echoes "hit" when the step name contains any --skip substring, else nothing.
# A `case` pattern's `)` confuses the parser inside `$( )`, so this is a plain
# loop over an IFS-split of the tab-joined skip list.
is_skipped() {
  _n="$1"
  [ -n "$SKIP" ] || return 0
  _old_ifs="$IFS"; IFS="$TAB"
  for _sv in $SKIP; do
    [ -n "$_sv" ] || continue
    case "$_n" in
      *"$_sv"*) IFS="$_old_ifs"; echo hit; return 0 ;;
    esac
  done
  IFS="$_old_ifs"
  return 0
}

# ── One pin, measured ────────────────────────────────────────────────────────
measure_pin() {
  pf="$1"; pl="$2"; pname="$3"; pnode="$4"

  body="$(extract_body "$pf" "$pl")"
  tee_file="$(tee_path_of "$body")"
  [ -n "$tee_file" ] || die2 "step '$pname' has no \`| tee /tmp/…\` line in its run body — this script cannot tell where its TAP lands. Teach it, do not guess."

  case "$body" in
    *"$TALLY_AWK"*) : ;;
    *) die2 "step '$pname' does not use the field-wise \`# pass N\` awk this script recognises. Its tally may be a DIFFERENT quantity (\`# tests N\` counts skips and todos); refusing to re-derive it." ;;
  esac

  # `set -euo pipefail` would abort the body the moment the suite exits
  # non-zero, before the tally is written. We want the TAP either way.
  body="$(printf '%s\n' "$body" | sed 's/^set -euo pipefail$/set -u/')"

  # THE HONEST RUNTIME. The __app.test.mjs step is routed through
  # console-harness.sh by name — that script owns the resolution contract and
  # prints a MEASURED banner. Every other body gets a `node` shim of the same
  # resolved binary, so nothing runs on the box default.
  case "$body" in
    *"node --test cloud/priv/static/__app.test.mjs"*)
      body="$(printf '%s\n' "$body" | sed "s#node --test cloud/priv/static/__app\\.test\\.mjs#sh '$ROOT/$HARNESS_REL'#")"
      ;;
  esac

  shimdir="$(mktemp -d)"
  printf '#!/bin/sh\nexec %s "$@"\n' "$pnode" > "$shimdir/node"
  chmod +x "$shimdir/node"

  rm -f "$tee_file"
  out="$(cd "$ROOT" && PATH="$shimdir:$PATH" bash -c "$body" 2>&1)"; rc=$?
  rm -rf "$shimdir"

  if [ ! -s "$tee_file" ]; then
    printf '%s\n' "$out" | tail -n 25 >&2
    die3 "step '$pname' produced no TAP at $tee_file (its body exited $rc). Nothing was measured, so nothing is written."
  fi
  if ! grep -q '^# pass ' "$tee_file"; then
    echo "--- last 25 lines of $tee_file ---" >&2
    tail -n 25 "$tee_file" >&2
    die3 "step '$pname' wrote $tee_file but it carries no \`# pass N\` line. That output is not a node:test TAP stream, so there is no tally to read. Refusing to write a pin from it."
  fi

  # A RED SUITE'S PASS COUNT IS NOT ITS PIN.
  # The pin is what the suite reports when it is HEALTHY. A suite that is red
  # here because this box cannot give it what it needs (seal-predicate.test.mjs
  # curls a host and reads real git history; it reports 92 of 131 on a
  # developer machine) still prints a `# pass N` — and that N is a smaller,
  # environment-shaped number. Writing it would LOWER a two-sided pin to the
  # local environment's limitations, which is exactly the silent weakening the
  # owner's ruling forbids. So: measured, named, and refused.
  fails="$(awk 'NF == 3 && $2 == "fail" && $3 ~ /^[0-9]+$/ { s += $3 } END { print s + 0 }' "$tee_file")"
  if [ "${fails:-0}" -ne 0 ]; then
    echo "--- failing test names ---" >&2
    grep '^not ok ' "$tee_file" | head -n 10 >&2
    die3 "step '$pname' is RED here: its TAP reports ${fails} failing test(s). A red suite's \`# pass\` count is the count of what HAPPENED to work in this environment, not the pin. Refusing to read a pin off it. Fix the failures, or exclude this pin deliberately with --skip '<part of the step name>' and re-earn it where it can be green (CI)."
  fi

  awk "$TALLY_AWK" "$tee_file"
}

# ── The rewrite — four anchored slots, non-comment lines only ────────────────
# The replacement is index-based rather than a regex with a word boundary: awk
# implementations disagree about `\<`/`\>`, and a pin that silently failed to
# match its own slot is the failure mode this tool exists to remove. The rule
# is literal: `<prefix><old><suffix>` is replaced only when the character
# before it and the character after it are not digits, so `-ne 13` never
# touches `-ne 131` and `35-test` never touches `135-test`.
rewrite_pin() {
  rn="$1"; rl="$2"; rold="$3"; rnew="$4"
  tmp="$WF.console-pins.tmp"
  awk -v a="$rn" -v b="$rl" -v old="$rold" -v new="$rnew" '
    function isdigit(c) { return (c >= "0" && c <= "9") }
    function slot(line, pre, suf,   out, rest, needle, p, before, after, cut) {
      needle = pre old suf
      out = ""; rest = line
      while (1) {
        p = index(rest, needle)
        if (p == 0) break
        before = (p > 1) ? substr(rest, p - 1, 1) : ((out == "") ? "" : substr(out, length(out), 1))
        after  = substr(rest, p + length(needle), 1)
        cut = p + length(needle) - 1
        if ((before != "" && isdigit(before)) || (after != "" && isdigit(after))) {
          out = out substr(rest, 1, cut)
        } else {
          out = out substr(rest, 1, p - 1) pre new suf
        }
        rest = substr(rest, cut + 1)
      }
      return out rest
    }
    NR >= a && NR <= b {
      stripped = $0; sub(/^[ \t]*/, "", stripped)
      if (substr(stripped, 1, 1) != "#") {
        line = $0
        line = slot(line, "-ne ", "")
        line = slot(line, "pin is ", "")
        line = slot(line, "pin ", "")
        line = slot(line, "bump every ", "")
        line = slot(line, "", "-test")
        print line; next
      }
    }
    { print }
  ' "$WF" > "$tmp" && mv "$tmp" "$WF"
}

# ── The functional pin literals of one step ──────────────────────────────────
# The SAME five anchored slots rewrite_pin writes, read back out of the file:
#   `<N>-test`  ·  `-ne <N>`  ·  `pin is <N>`  ·  `bump every <N>`  ·  `pin <N>`
# Scanned from the step's `- name:` line (the `N-test` slot lives there) through
# the end of its run body, comment lines EXCLUDED — a pin comment's history
# sentences ("PIN 1459 — bumped 2026-09-15 from 1456") are the record and are
# supposed to hold old numbers. Prints the sorted-unique set, space-joined; a
# consistent step prints exactly its own pin and nothing else.
functional_literals() {
  sed -n "${1},${2}p" "$WF" | grep -v '^[[:space:]]*#' \
    | { grep -oE -e '-ne [0-9]+' -e 'bump every [0-9]+' -e 'pin is [0-9]+' -e 'pin [0-9]+' -e '[0-9]+-test' || true; } \
    | sed -E 's/^.*[^0-9]([0-9]+)$/\1/; s/^([0-9]+)-test$/\1/' \
    | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# ── selftest — the predicate must be able to say YES and to say NO ───────────
selftest() {
  pass=0; fail=0
  ok()  { pass=$((pass + 1)); echo "  ok   — $1"; }
  bad() { fail=$((fail + 1)); echo "  FAIL — $1" >&2; }

  rows="$(enumerate "$WF")"
  n="$(printf '%s' "$rows" | grep -c . || true)"
  if [ "${n:-0}" -ge 1 ]; then ok "the predicate finds $n pin step(s) in $WF_REL"
  else bad "the predicate found NOTHING in $WF_REL — it has gone blind, and --check would then report a vacuous zero drift"; fi

  # It must say NO. Strip the red sentence and the pin set must go empty.
  d="$(mktemp -d)"
  sed 's/the committed pin is/the committed NOTHING is/' "$WF" > "$d/no-pins.yml"
  if [ -z "$(enumerate "$d/no-pins.yml")" ]; then
    ok "…and says NO on the same workflow with its pin sentences removed"
  else
    bad "…still matched a workflow carrying no pin sentence — the predicate cannot say NO, so its selection means nothing"
  fi
  rm -rf "$d"

  # Every enumerated step must be interpretable and internally consistent.
  printf '%s\n' "$rows" | while IFS="$TAB" read -r nl f l pv nm; do
    [ -n "${f:-}" ] || continue
    b="$(extract_body "$f" "$l")"
    t="$(tee_path_of "$b")"
    if [ -n "$t" ]; then ok "$nm -> TAP at $t"; else bad "$nm has no tee target"; fi
    case "$b" in
      *"$TALLY_AWK"*) ok "…sums \`# pass N\` field-wise, not \`# tests N\`" ;;
      *) bad "…does not use the recognised \`# pass N\` awk" ;;
    esac
    # EVERY FUNCTIONAL SLOT, NOT ONLY \`-ne\` (task-4a591a26279e7d24). A pin is
    # spelled out in FIVE places per step — the step NAME's \`N-test\`, the
    # gutted-tree self-test's \`-ne N\`, the verdict's \`-ne N\`, the red
    # sentence's \`pin is N\`, its \`bump every N\` instruction to the next
    # author, and the green line's \`exact pin N\`. Checking one of them let a
    # HALF-DONE bump pass: with \`-ne\`/\`pin is\` at the new number and the name,
    # the \`bump every\` instruction and the green line still at the old one, the
    # gate stayed green and the workflow went on TELLING the next author to bump
    # a number that is no longer the pin. Same slot set the rewriter writes
    # (rewrite_pin), scanned over the step NAME line through the run body, so
    # what is rewritten is exactly what is checked. Comment lines are excluded:
    # the PIN-history log is the record of what the count USED to be and must
    # keep saying so.
    others="$(functional_literals "$nl" "$l")"
    if [ "$others" = "$pv" ]; then ok "…and every functional pin literal in the step (name \`N-test\`, \`-ne\`, \`pin is\`, \`bump every\`, \`pin\`) reads $pv"
    else bad "$nm: the step's functional pin literals are [$others] but its red sentence says $pv — this pin is internally inconsistent, so at least one hardcoded count here is a number no instrument stands behind (a half-done bump leaves the old value in the slots nobody edited)"; fi
  done > "$d.sel" 2>"$d.selerr" || true
  cat "$d.sel"; cat "$d.selerr" >&2
  # The loop above runs in a pipeline subshell, so re-derive the verdict from
  # what it printed rather than from counters it could not export.
  sp="$(grep -c '^  ok   —' "$d.sel" || true)"
  sf="$(grep -c '^  FAIL —' "$d.selerr" || true)"
  rm -f "$d.sel" "$d.selerr"
  pass=$((pass + sp)); fail=$((fail + sf))

  echo "console-pins --selftest: $pass passed / $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
}

[ "$MODE" = "--selftest" ] && selftest

ROWS="$(enumerate "$WF")"
[ -n "$ROWS" ] || die2 "the pin predicate matched nothing in $WF_REL. Either the red sentence changed wording (update the predicate here, deliberately) or the pins are gone — an empty pin set is indistinguishable from a broken predicate, so this is a refusal and not a clean run."

if [ "$MODE" = "--list" ]; then
  printf '%-4s %-64s %6s  %s\n' "LINE" "STEP" "PIN" "TAP"
  printf '%s\n' "$ROWS" | while IFS="$TAB" read -r nl f l pv nm; do
    [ -n "${f:-}" ] || continue
    if [ -n "$ONLY" ]; then case "$nm" in *"$ONLY"*) : ;; *) continue ;; esac; fi
    [ -n "$(is_skipped "$nm")" ] && continue
    printf '%-4s %-64s %6s  %s\n' "$nl" "$(printf '%.64s' "$nm")" "$pv" "$(tee_path_of "$(extract_body "$f" "$l")")"
  done
  exit 0
fi

NODE_BIN_RESOLVED="$(resolve_node)" || exit $?
echo "console-pins: measuring on $NODE_BIN_RESOLVED ($("$NODE_BIN_RESOLVED" --version))"
echo

DRIFT=0
WROTE=0
SELECTED=0
SKIPPED=0
# The loop must run in THIS shell (the counters are the verdict), so the rows
# arrive by here-doc rather than through a pipe.
while IFS="$TAB" read -r nl f l pv nm; do
  [ -n "${f:-}" ] || continue
  if [ -n "$ONLY" ]; then case "$nm" in *"$ONLY"*) : ;; *) continue ;; esac; fi
  if [ -n "$SKIP" ]; then
    hit="$(is_skipped "$nm")"
    if [ -n "$hit" ]; then echo "── $nm"; echo "   SKIPPED by --skip (this pin was NOT measured and NOT verified)"; echo; SKIPPED=$((SKIPPED + 1)); continue; fi
  fi
  SELECTED=$((SELECTED + 1))
  echo "── $nm"
  measured="$(measure_pin "$f" "$l" "$nm" "$NODE_BIN_RESOLVED")" || exit $?
  if [ "$measured" = "$pv" ]; then
    echo "   pin $pv · measured $measured · OK"
  else
    DRIFT=$((DRIFT + 1))
    echo "   pin $pv · measured $measured · DRIFT"
    if [ "$MODE" = "--write" ]; then
      rewrite_pin "$nl" "$l" "$pv" "$measured"
      left="$(sed -n "${nl},${l}p" "$WF" | grep -v '^[[:space:]]*#' \
              | grep -oE "(-ne|pin|pin is|bump every) $pv([^0-9]|\$)" | head -n 1 || true)"
      if [ -n "$left" ]; then
        die2 "rewrote '$nm' to $measured but a functional slot still reads $pv ('$left'). The file is half-written — inspect it before committing."
      fi
      other="$(sed -n "${nl},${l}p" "$WF" | grep -v '^[[:space:]]*#' | grep -nE "(^|[^0-9])$pv([^0-9]|\$)" || true)"
      [ -n "$other" ] && { echo "   NOTE — $pv still appears on a non-comment line in this step; read it, it may be unrelated:"; printf '%s\n' "$other" | sed 's/^/     /'; }
      echo "   rewritten $pv -> $measured"
      WROTE=$((WROTE + 1))
    fi
  fi
  echo
done <<EOF
$ROWS
EOF

[ "$SELECTED" -gt 0 ] || die2 "--only '$ONLY' selected no pin step. An empty selection is indistinguishable from a broken filter, so this is a refusal."

if [ "$MODE" = "--write" ]; then
  echo "console-pins: $SELECTED pin(s) measured, $WROTE rewritten, $SKIPPED skipped."
  exit 0
fi

if [ "$DRIFT" -eq 0 ]; then
  echo "console-pins: $SELECTED pin(s) measured, $SKIPPED skipped, no drift — every measured pin equals what its own instrument just printed."
  exit 0
fi
echo "console-pins: $SELECTED pin(s) measured, $SKIPPED skipped, $DRIFT drifted. Run \`bash scripts/console-pins.sh --write\` to re-earn them."
exit 1
