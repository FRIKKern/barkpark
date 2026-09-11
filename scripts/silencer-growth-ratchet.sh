#!/usr/bin/env bash
# silencer-growth-ratchet.sh — the shrink-only count ratchet over this repo's
# SILENCER FILES (task cgsi-bl-baseline-laundering-estate, guards-that-can-lose).
#
# WHAT A SILENCER FILE IS. A file whose only job is to make some other gate stop
# reporting a finding: a baseline of grandfathered hits, a skips list, an inline
# waiver marker. Every one of them is legitimate — you cannot land a gate over a
# tree that already violates it without grandfathering what is there. The defect
# is not that they exist; it is that in this repo they had no direction. Each one
# can be REGENERATED in a single command on any laptop, and no gate anywhere
# compared the result to the previous revision. tenant-scope-check.sh even
# ADVERTISES its own regeneration in the text of its failure message, so the
# documented cure for a RED is a command that turns it GREEN with the finding
# still live in the tree.
#
# WHAT THIS FIXES, and only this. It pins a COUNT per silencer in a committed
# roster (scripts/.silencer-counts) and REDS when a count GROWS. Shrinking is
# always allowed and never reds — the whole point of a shrink-only ratchet is
# that paying down a baseline must stay frictionless while adding to one must
# cost a visible, reviewable, second-file bump. It does NOT read the CONTENT of
# any silencer, does not judge whether an individual waiver is justified, and
# does not stop a regeneration; a green here means "no silencer holds more
# entries than the roster says", and nothing larger.
#
# WHY A COUNT AND NOT A DIFF. A content diff over six heterogeneous formats
# (TSV baseline, CSV skips, JSON manifest, inline source markers) is six parsers
# that each rot on their own schedule; a count is one comparison that cannot
# silently start matching nothing. The repo already runs this exact shape for
# gofmt in scripts/go-format-drift-ceiling.sh, which this script is modelled on.
#
# REFUSAL, NOT A GREEN. Copied deliberately from scripts/dependabot-roots-check.sh
# and scripts/console-runtime-pin-check.sh: if this gate cannot MEASURE — a named
# silencer file is gone, the roster is missing, a roster line is unparsable, the
# roster and the table disagree about which silencers exist — it exits 2 as
# HARNESS-UNAVAILABLE. A guard that cannot see must never report clean, because a
# deleted target and a clean target are indistinguishable in a count of zero.
#
# WHY .go-format-drift-ceiling IS NOT ON THE ROSTER. It is already ratcheted, by
# a BLOCKING job, in .github/workflows/go-format.yml. Guarding it twice would put
# two gates on one number and make a legitimate prune red one of them.
#
# BLAST RADIUS, said plainly. This runs as a step in .github/workflows/doc-gates.yml,
# whose job publishes the "Doc budgets + anchors" context. That context carries an
# explicit S4 exclusion row in .github/required-checks.json, so it is NOT in the
# required set: a RED here is VISIBLE on the pull request and CANNOT stop a merge.
# Wiring it here makes it RUN, not BLOCK. The blocking half of this fix is the
# CODEOWNERS recommendation recorded on the pull request, not this file.
#
# USAGE:
#   bash scripts/silencer-growth-ratchet.sh            # enforce the ratchet
#   bash scripts/silencer-growth-ratchet.sh --selftest # prove the gate can fail
#
# EXIT CODES:  0 = no growth   1 = a silencer GREW   2 = cannot measure (refusal)
#
# Overrides (used only by --selftest to drive throwaway trees):
#   SILENCER_ROOT    tree to measure         (default: the git toplevel)
#   SILENCER_ROSTER  roster path             (default: $ROOT/scripts/.silencer-counts)
#   SILENCER_TABLE   newline-separated table (default: the built-in table below)
#
# bash 3.2 compatible (macOS ships 3.2): no mapfile, no associative arrays.

set -uo pipefail

# ── the table: name|mode|spec ────────────────────────────────────────────────
# modes:
#   entries            non-blank, non-comment lines of ONE file
#   lines              total lines of ONE file (a JSON manifest has no comments)
#   occurrences:<str>  occurrences of a fixed string under one or more directories
DEFAULT_TABLE='tenant-scope-baseline|entries|scripts/tenant-scope-baseline.txt
sobelow-skips|entries|api/.sobelow-skips
status-manifest|lines|design/status-manifest.json
lit-allow-go|occurrences:lit-allow|cmd internal
lit-allow-web|occurrences:lit-allow|web
lit-allow-api|occurrences:lit-allow|api/lib'

# ── measurement ──────────────────────────────────────────────────────────────
# measure ROOT MODE SPEC -> prints the count on stdout, or a reason on stderr
# and returns 2. Returning 2 is the ONLY way this function reports "unknown";
# it never prints 0 for something it could not look at.
measure() {
  local root="$1" mode="$2" spec="$3"

  case "$mode" in
    entries|lines)
      local f="$root/$spec"
      if [ ! -f "$f" ]; then
        echo "missing file: $spec" >&2
        return 2
      fi
      if [ "$mode" = "lines" ]; then
        grep -c '' "$f" 2>/dev/null || echo 0
      else
        grep -vcE '^[[:space:]]*(#|$)' "$f" 2>/dev/null || echo 0
      fi
      ;;
    occurrences:*)
      local needle="${mode#occurrences:}" d total=0 n
      for d in $spec; do
        if [ ! -d "$root/$d" ]; then
          echo "missing directory: $d" >&2
          return 2
        fi
        # -o one hit per line, -h no filename, -I skip binaries, -F literal.
        # `|| true` on the count: grep -c exits 1 on zero matches AND prints 0.
        n="$( grep -rIohF -- "$needle" "$root/$d" 2>/dev/null | grep -c '' || true )"
        [ -n "$n" ] || n=0
        total=$(( total + n ))
      done
      printf '%s\n' "$total"
      ;;
    *)
      echo "unknown mode: $mode" >&2
      return 2
      ;;
  esac
  return 0
}

# ── the ratchet ──────────────────────────────────────────────────────────────
# run_ratchet ROOT ROSTER TABLE -> 0 ok, 1 growth, 2 refusal
run_ratchet() {
  local root="$1" roster="$2" table="$3"

  if [ ! -f "$roster" ]; then
    echo "REFUSE: roster not found at $roster — a guard that cannot compare must not report clean."
    echo "        (exit 2 = harness unavailable, NOT a pass.)"
    return 2
  fi

  # Parse the roster into "name count" pairs. Comments and blank lines ignored.
  local roster_pairs
  roster_pairs="$(grep -vE '^[[:space:]]*(#|$)' "$roster" | awk '{print $1" "$2}')"

  local rc=0 grew=0 shrank=0 checked=0
  local line name mode spec want cur err

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%|*}"
    local rest="${line#*|}"
    mode="${rest%%|*}"
    spec="${rest#*|}"

    want="$(printf '%s\n' "$roster_pairs" | awk -v n="$name" '$1==n {print $2; found=1} END{ if(!found) print "" }')"
    if [ -z "$want" ]; then
      echo "REFUSE: silencer '$name' has no entry in the roster ($roster)."
      echo "        Add a line '$name <count>' — an unrostered silencer is unmeasured, not clean."
      return 2
    fi
    case "$want" in
      ''|*[!0-9]*)
        echo "REFUSE: roster entry for '$name' is not a non-negative integer: '$want'"
        return 2
        ;;
    esac

    err="$(measure "$root" "$mode" "$spec" 2>&1 >/dev/null)"
    cur="$(measure "$root" "$mode" "$spec" 2>/dev/null)"
    if [ -n "$err" ] || [ -z "$cur" ]; then
      echo "REFUSE: cannot measure silencer '$name' — ${err:-no count produced}."
      echo "        A named silencer that is not there is a HOLE, not a zero. Exit 2."
      return 2
    fi

    checked=$(( checked + 1 ))
    if [ "$cur" -gt "$want" ]; then
      echo "FAIL: silencer GREW — $name: $want -> $cur (+$(( cur - want ))) [$mode $spec]"
      grew=1
      rc=1
    elif [ "$cur" -lt "$want" ]; then
      echo "note: silencer shrank — $name: $want -> $cur (-$(( want - cur ))). Allowed; lower the roster when convenient."
      shrank=1
    fi
  done <<EOF
$table
EOF

  if [ "$checked" -eq 0 ]; then
    echo "REFUSE: measured 0 silencers — an empty table cannot produce a meaningful green."
    return 2
  fi

  # Roster lines naming nothing in the table: a silencer was retired but its row
  # survives, or a typo means the row we THINK is guarding something guards air.
  local rname
  while IFS= read -r rname; do
    [ -n "$rname" ] || continue
    if ! printf '%s\n' "$table" | grep -q "^${rname}|"; then
      echo "REFUSE: roster names '$rname', which this gate does not measure — a stale roster row guards nothing."
      return 2
    fi
  done <<EOF
$(printf '%s\n' "$roster_pairs" | awk '{print $1}')
EOF

  if [ "$grew" -eq 1 ]; then
    echo ""
    echo "A silencer file gained entries. That is allowed — but it must be DELIBERATE:"
    echo "  1. justify the new entries in the pull request body, and"
    echo "  2. raise the matching number in $roster in the SAME commit."
    echo "Do NOT 'fix' this by regenerating a baseline; regeneration is what this gate exists to make visible."
    return 1
  fi

  if [ "$shrank" -eq 1 ]; then
    echo "OK: $checked silencer(s) measured; none grew (some shrank — see notes above)."
  else
    echo "OK: $checked silencer(s) measured; none grew."
  fi
  return 0
}

# ── self-test (tripwire) ─────────────────────────────────────────────────────
# Every arm builds a throwaway tree and re-invokes the SHIPPING functions above.
# It plants nothing in the real tree.
selftest() {
  local tmp; tmp="$(mktemp -d)"
  local fails=0

  _mk() { # _mk DIR — a minimal tree with one of each silencer shape
    local d="$1"
    mkdir -p "$d/scripts" "$d/design" "$d/api" "$d/cmd"
    printf '# header\nalpha\nbeta\n' > "$d/scripts/base.txt"          # entries = 2
    printf '{\n"a": 1\n}\n' > "$d/design/manifest.json"                # lines   = 3
    printf 'x // lit-allow\ny\nz // lit-allow\n' > "$d/cmd/main.go"    # occ     = 2
  }
  local T='b|entries|scripts/base.txt
m|lines|design/manifest.json
o|occurrences:lit-allow|cmd'

  _roster() { printf '# counts\nb %s\nm %s\no %s\n' "$1" "$2" "$3"; }

  _arm() { # _arm LABEL EXPECTED_RC ROOT ROSTER TABLE [GREP]
    local label="$1" want_rc="$2" root="$3" ros="$4" tab="$5" pat="${6:-}"
    local out rc
    out="$(run_ratchet "$root" "$ros" "$tab" 2>&1)"; rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
      echo "SELFTEST FAIL ($label): expected rc=$want_rc, got rc=$rc"
      printf '%s\n' "$out" | sed 's/^/      | /'
      fails=1
      return
    fi
    if [ -n "$pat" ] && ! printf '%s' "$out" | grep -q -- "$pat"; then
      echo "SELFTEST FAIL ($label): rc=$rc correct but output did not mention '$pat'"
      printf '%s\n' "$out" | sed 's/^/      | /'
      fails=1
      return
    fi
    echo "SELFTEST ok ($label)"
  }

  # A — a roster that matches reality passes.
  local A="$tmp/A"; _mk "$A"; _roster 2 3 2 > "$A/roster"
  _arm "A: exact match passes" 0 "$A" "$A/roster" "$T" "none grew"

  # B — one MORE entry in the line-based baseline reds, naming the file+delta.
  local B="$tmp/B"; _mk "$B"; _roster 2 3 2 > "$B/roster"
  printf 'gamma\n' >> "$B/scripts/base.txt"
  _arm "B: baseline growth reds, named" 1 "$B" "$B/roster" "$T" "b: 2 -> 3"

  # C — one MORE inline marker reds. Same ratchet, different measurement shape.
  local C="$tmp/C"; _mk "$C"; _roster 2 3 2 > "$C/roster"
  printf 'w // lit-allow\n' >> "$C/cmd/main.go"
  _arm "C: inline-marker growth reds" 1 "$C" "$C/roster" "$T" "o: 2 -> 3"

  # D — one MORE JSON line reds (the manifest has no comment syntax to hide in).
  local D="$tmp/D"; _mk "$D"; _roster 2 3 2 > "$D/roster"
  printf '\n' >> "$D/design/manifest.json"
  _arm "D: manifest growth reds" 1 "$D" "$D/roster" "$T" "m: 3 -> 4"

  # E — a SHRINK must NOT red. This is the whole point of shrink-only: paying a
  # baseline down has to stay free, or the ratchet becomes a reason not to.
  local E="$tmp/E"; _mk "$E"; _roster 5 9 7 > "$E/roster"
  _arm "E: shrink passes with a note" 0 "$E" "$E/roster" "$T" "shrank"

  # F — REFUSAL: a named silencer file is GONE. Its count would read 0, which is
  # smaller than the roster and would sail through as a "shrink". That is the
  # exact way this gate could go blind, so absence must exit 2, not 0.
  local F="$tmp/F"; _mk "$F"; _roster 2 3 2 > "$F/roster"
  rm -f "$F/scripts/base.txt"
  _arm "F: missing target REFUSES (2), never greens as a shrink" 2 "$F" "$F/roster" "$T" "missing file"

  # G — REFUSAL: a missing scan DIRECTORY, the same hole in the other shape.
  local G="$tmp/G"; _mk "$G"; _roster 2 3 2 > "$G/roster"
  rm -rf "$G/cmd"
  _arm "G: missing scan directory REFUSES (2)" 2 "$G" "$G/roster" "$T" "missing directory"

  # H — REFUSAL: no roster at all.
  local H="$tmp/H"; _mk "$H"
  _arm "H: absent roster REFUSES (2)" 2 "$H" "$H/roster" "$T" "roster not found"

  # I — REFUSAL: a silencer in the table with no roster row. An unrostered
  # silencer is unmeasured, and an unmeasured silencer must not read as clean.
  local I="$tmp/I"; _mk "$I"; printf 'b 2\nm 3\n' > "$I/roster"
  _arm "I: table entry missing from roster REFUSES (2)" 2 "$I" "$I/roster" "$T" "no entry in the roster"

  # J — REFUSAL: a roster row naming nothing this gate measures (a retired
  # silencer's row left behind looks like coverage and is not).
  local J="$tmp/J"; _mk "$J"; { _roster 2 3 2; printf 'ghost 4\n'; } > "$J/roster"
  _arm "J: stale roster row REFUSES (2)" 2 "$J" "$J/roster" "$T" "guards nothing"

  # K — REFUSAL: a non-numeric roster value. A typo'd count must not compare.
  local K="$tmp/K"; _mk "$K"; printf 'b two\nm 3\no 2\n' > "$K/roster"
  _arm "K: non-integer roster value REFUSES (2)" 2 "$K" "$K/roster" "$T" "not a non-negative integer"

  # L — REFUSAL: an empty table. Zero comparisons is a vacuous green otherwise —
  # the failure mode go-format-drift-ceiling's MIN_FILES floor exists to stop.
  local L="$tmp/L"; _mk "$L"; _roster 2 3 2 > "$L/roster"
  _arm "L: empty table REFUSES (2), no vacuous green" 2 "$L" "$L/roster" "" "measured 0 silencers"

  # M — REFUSAL: an unknown mode (a future table typo) must not measure to 0.
  local M="$tmp/M"; _mk "$M"; printf 'b 2\n' > "$M/roster"
  _arm "M: unknown mode REFUSES (2)" 2 "$M" "$M/roster" 'b|bogusmode|x' "unknown mode"

  # N — NON-VACUITY of arm A: prove the passing arm is comparing at all. If the
  # comparison were deleted, A would still pass; this arm shows a roster ONE
  # below reality reds, so A's green is a measurement and not an empty loop.
  local N="$tmp/N"; _mk "$N"; _roster 1 3 2 > "$N/roster"
  _arm "N: off-by-one roster reds (arm A is non-vacuous)" 1 "$N" "$N/roster" "$T" "b: 1 -> 2"

  rm -rf "$tmp"
  if [ "$fails" -ne 0 ]; then echo "SELFTEST: FAILURES ABOVE"; return 1; fi
  echo "SELFTEST: 14 arms passed — the ratchet reds on growth in all three shapes,"
  echo "          stays green on a shrink, and REFUSES (2) rather than greening"
  echo "          whenever it cannot measure."
  return 0
}

# ── entry ────────────────────────────────────────────────────────────────────
# Refuse an argument this gate does not understand: a swallowed flag would run
# the ordinary check and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "silencer-growth-ratchet: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

ROOT="${SILENCER_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROSTER="${SILENCER_ROSTER:-$ROOT/scripts/.silencer-counts}"
TABLE="${SILENCER_TABLE:-$DEFAULT_TABLE}"
run_ratchet "$ROOT" "$ROSTER" "$TABLE"
exit $?
