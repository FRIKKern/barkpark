#!/usr/bin/env bash
# echo-json-parse-guard.test.sh — `echo "$json" | jq` corrupts the payload in
# every escape-interpreting shell, and the way it fails manufactures a uniform
# false ABSENCE (task-8a5fb4bf0915b5b2).
#
# ── THE FAULT ───────────────────────────────────────────────────────────────
# A JSON string carrying `\n`, `\t` or `\\` is TWO characters on the wire. An
# `echo` that interprets backslash escapes collapses each pair into one real
# control character INSIDE the string — which is exactly what RFC 8259 §7
# forbids unescaped — so jq refuses the whole document:
#
#   jq: parse error: Invalid string: control characters from U+0000 through
#       U+001F must be escaped
#
# It is a property of the SHELL, not of bp and not of the row:
#
#   shell  echo interprets escapes?   echo "$json" | jq -r .x
#   bash   NO                         parses           SAFE
#   sh     YES (dash; macOS bash-as-sh has xpg_echo)   parse error   CORRUPTS
#   zsh    YES                        parse error      CORRUPTS
#
# bash's safety is NOT a defence: the recipes an agent pastes land in an
# interactive zsh, where the same line corrupts.
#
# ── WHY IT IS WORSE THAN A SYNTAX NOTE: FALSE ABSENCE ───────────────────────
# The corruption is UNIFORM. Every row with an escape in it fails the same
# way, so a loop that swallows jq's stderr prints an empty field for EVERY
# row and reads as a fact about the DATA — "these rows have no evidence" —
# rather than as a fault in the pipe. The row that filed this was an audit of
# eight closes: seven of eight printed a blank lifecycle, 0/0 criteria and
# "no sha in evidence". Re-read through a tolerant writer, all eight were
# `done`, fully met, every cited commit on main. A uniform verdict is the
# signature of a broken instrument, and this instrument manufactures an
# ABSENCE — the one class inspection never catches, because there is nothing
# to look at.
#
# ── THE SAFE FORMS ──────────────────────────────────────────────────────────
#   bp … -o json > "$f" && jq … "$f"     redirect, then read the file
#   bp … -o json | jq …                  pipe the command directly
#   printf '%s' "$j" | jq …              when a variable must be re-emitted
#   print -r -- "$j" | jq …              zsh-only equivalent
#
# ── WHAT THIS CHECK ASSERTS, AND WHY IT CANNOT PASS VACUOUSLY ───────────────
# Every arm drives a REAL jq over a REAL captured bp row
# (scripts/fixtures/echo-json-parse-row.json — the very task that filed this,
# 64 `\n` + 38 `\"` + 6 `\\` sequences on the wire, zero raw control characters).
#   · Clause A proves the FIXTURE is innocent: valid JSON as a file, and no
#     raw byte below 0x20 in it. A doctored fixture cannot fake the failure.
#   · Clause B is the BASH CONTROL. It asserts echo SUCCEEDS there. If the
#     whole thing were "jq is broken" or "the fixture is bad", B reds.
#   · Clause C asserts the corrupting shell FAILS *by its error text*, and
#     the same payload through printf PARSES to the *same decoded value* bash
#     got. Both directions are asserted, so the check cannot be satisfied by
#     jq never running, and it cannot survive the fault being fixed upstream:
#     if `sh`'s echo stopped interpreting escapes, C1 reds by name.
#   · Clause E guards the DOCS: no `echo "$var"` feeding jq may return to the
#     agent-facing recipes, and the false-absence wording must still be there.
#
# TESTED BY: itself. Hermetic — no network, no bp, frozen fixture.
# EXIT CODES: 0 all arms passed · 1 an arm failed.

# SC2016 is DELIBERATE throughout: the snippets below must reach the child
# shell UNEXPANDED — expanding `$j` here would substitute this bash's value and
# the child would never run the recipe under test.
# shellcheck disable=SC2016
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

FIXTURE="scripts/fixtures/echo-json-parse-row.json"
SKILL=".claude/skills/session/SKILL.md"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
note(){ printf '     %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "echo-json-parse-guard: jq is REQUIRED — this check is about jq's parser, so a jq-less pass would be vacuous" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "echo-json-parse-guard: fixture missing: $FIXTURE" >&2; exit 1; }

# The decoded value every writer must agree on. It crosses the escaped region:
# .doc.content.description is the field carrying the 62 `\n`.
JQ_PATH='.doc.content.lifecycle_status + "/" + (.doc.content.description | length | tostring)'

echo "── A. the fixture is innocent (bp is not at fault) ────────────────────"

if EXPECTED="$(jq -r "$JQ_PATH" "$FIXTURE" 2>&1)" && [ -n "$EXPECTED" ] && [ "${EXPECTED#*/}" != "$EXPECTED" ]; then
  ok "A1 the fixture parses as a FILE: $JQ_PATH -> $EXPECTED"
else
  no "A1 the fixture does not parse as a file — jq said: $EXPECTED"
  EXPECTED=""
fi

# Raw control characters, counted without perl: total bytes minus bytes left
# after deleting the 0x00-0x1f range, minus the file's own trailing newline.
RAWCTRL=$(( $(wc -c < "$FIXTURE") - $(tr -d '\000-\037' < "$FIXTURE" | wc -c) - 1 ))
if [ "$RAWCTRL" = "0" ]; then
  ok "A2 the fixture carries ZERO raw control characters below 0x20 — the corruption below is introduced by the pipe, not present on the wire"
else
  no "A2 the fixture already carries $RAWCTRL raw control characters — it cannot prove the pipe introduced them"
fi

ESCN="$(grep -o '\\n' "$FIXTURE" | wc -l | tr -d ' ')"
if [ "$ESCN" -ge 10 ]; then
  ok "A3 the fixture carries $ESCN escaped \\n sequences — enough for an escape-interpreting echo to break it"
else
  no "A3 the fixture carries only $ESCN escaped \\n sequences — too few to exercise the fault (the subject has been mutated away)"
fi

# One helper per shell: run a snippet with the fixture's bytes in $j.
# `$1` is the interpreter, `$2` the snippet. stderr is folded in on purpose —
# the error text IS the assertion.
run_in() {
  "$1" -c 'j=$(cat "$1"); shift; eval "$@"' _ "$FIXTURE" "$2" 2>&1
}
bytes_in() {
  "$1" -c 'j=$(cat "$1"); shift; eval "$@" | wc -c' _ "$FIXTURE" "$2" 2>/dev/null | tr -d ' '
}

echo
echo "── B. the bash CONTROL: echo does NOT corrupt there ───────────────────"

if [ -x /bin/bash ]; then
  GOT="$(run_in /bin/bash "echo \"\$j\" | jq -r '$JQ_PATH'")"
  if [ -n "$EXPECTED" ] && [ "$GOT" = "$EXPECTED" ]; then
    ok "B1 bash:  echo \"\$j\" | jq  -> $GOT   (SAFE — so this is not 'jq is broken' and not a bad fixture)"
  else
    no "B1 bash's echo should NOT corrupt; expected '$EXPECTED', got: $GOT"
  fi
else
  no "B1 /bin/bash absent — the control arm cannot run, so no corrupting-shell verdict below means anything"
fi

echo
echo "── C/D. the corrupting shells: echo FAILS, printf PARSES ──────────────"

CORRUPTORS_SEEN=0
check_corrupting_shell() {
  local label="$1" shpath="$2"
  if [ ! -x "$shpath" ]; then
    note "$label SKIPPED — $shpath is not present on this machine"
    return
  fi

  local got_echo got_printf b_echo b_printf delta
  got_echo="$(run_in "$shpath" "echo \"\$j\" | jq -r '$JQ_PATH'")"

  case "$got_echo" in
    *"control characters from U+0000"*)
      CORRUPTORS_SEEN=$((CORRUPTORS_SEEN + 1))
      ok "$label.1 echo \"\$j\" | jq  -> REFUSED, and by the right error:"
      note "        ${got_echo%%$'\n'*}"
      ;;
    "$EXPECTED")
      no "$label.1 echo \"\$j\" | jq PARSED on $shpath. Either this shell's echo stopped interpreting escapes or the fixture lost its escapes — either way this check is no longer measuring the fault it was written for."
      ;;
    *)
      no "$label.1 echo \"\$j\" | jq failed on $shpath, but NOT with the control-character parse error. Got: $got_echo"
      ;;
  esac

  got_printf="$(run_in "$shpath" "printf '%s' \"\$j\" | jq -r '$JQ_PATH'")"
  if [ -n "$EXPECTED" ] && [ "$got_printf" = "$EXPECTED" ]; then
    ok "$label.2 printf '%s' \"\$j\" | jq  -> $got_printf   (the SAME decoded value bash's echo produced)"
  else
    no "$label.2 printf '%s' \"\$j\" | jq should have produced '$EXPECTED' on $shpath; got: $got_printf"
  fi

  b_echo="$(bytes_in "$shpath" 'echo "$j"')"
  b_printf="$(bytes_in "$shpath" 'printf "%s" "$j"')"
  if [ -n "$b_echo" ] && [ -n "$b_printf" ] && [ "$b_echo" -lt "$b_printf" ]; then
    # echo appends a newline printf does not, so the true loss is one MORE
    # than the raw difference. Report the raw delta and the collapse count.
    delta=$((b_echo - b_printf))
    ok "$label.3 printf bytes=$b_printf   echo bytes=$b_echo   delta=$delta   ($((-delta + 1)) characters collapsed, net of echo's trailing newline)"
  else
    no "$label.3 expected echo to emit FEWER bytes than printf on $shpath; printf=$b_printf echo=$b_echo"
  fi
}

check_corrupting_shell C /bin/sh
ZSH="$(command -v zsh 2>/dev/null || true)"
if [ -n "$ZSH" ]; then check_corrupting_shell D "$ZSH"; else note "D SKIPPED — no zsh on this machine"; fi

if [ "$CORRUPTORS_SEEN" -ge 1 ]; then
  ok "C/D at least one escape-interpreting shell was actually measured ($CORRUPTORS_SEEN) — the corrupting half of this check is not vacuous"
else
  no "C/D NO corrupting shell was measured. Every arm above skipped or passed, which would make this file a green with no subject."
fi

echo
echo "── E. the guidance an agent pastes ────────────────────────────────────"

if [ -f "$SKILL" ]; then
  # Scan the EXECUTABLE surface only: the contents of the fenced bash blocks, which is
  # what an agent copies into its shell. Prose is exempt on purpose — this file
  # now NAMES the unsafe forms in order to forbid them, and a guard that cannot
  # tell a prohibition from a recipe reds on its own warning label.
  # Both unsafe shapes are caught: the pipe, and the process substitution.
  FENCED="$(awk '
    /^```bash$/ { inb = 1; next }
    /^```/      { inb = 0; next }
    inb         { print FNR ":" $0 }
  ' "$SKILL")"
  if [ -z "$FENCED" ]; then
    no "E0 no fenced bash blocks found in $SKILL — the guard below would pass over an empty set"
  else
    ok "E0 scanning $(printf '%s\n' "$FENCED" | wc -l | tr -d ' ') fenced bash lines in $SKILL — the guard has a subject"
  fi
  UNSAFE="$(printf '%s\n' "$FENCED" | grep -E '(\||<\()[[:space:]]*echo[[:space:]]+"?\$[A-Za-z_{]' || true)"
  if [ -z "$UNSAFE" ]; then
    ok "E1 $SKILL carries NO 'echo \"\$var\"' feeding jq — neither the pipe form nor the <(…) form"
  else
    no "E1 $SKILL has re-grown an unsafe echo-into-jq recipe. An agent pastes these into zsh, where they corrupt:"
    printf '%s\n' "$UNSAFE" | sed 's/^/        /'
  fi

  if grep -qi 'false absence' "$SKILL" && grep -qi 'uniform' "$SKILL"; then
    ok "E2 $SKILL still states the FALSE-ABSENCE failure mode (uniform across rows -> reads as missing data, not as a broken pipe)"
  else
    no "E2 $SKILL no longer states the FALSE-ABSENCE failure mode. The syntax fix alone does not survive: the next author has to know WHY, or they reintroduce it."
  fi

  if grep -q "printf '%s'" "$SKILL"; then
    ok "E3 $SKILL names a safe form (printf '%s') for re-emitting a JSON variable"
  else
    no "E3 $SKILL no longer names a safe form for re-emitting a JSON variable"
  fi
else
  no "E  $SKILL is missing — the recipes this check guards are gone or moved"
fi

echo
echo "─────────────────────────────────────────────────────────────────────"
printf '%s passed / %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
