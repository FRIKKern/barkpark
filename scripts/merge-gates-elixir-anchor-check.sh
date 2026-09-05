#!/usr/bin/env bash
#
# merge-gates-elixir-anchor-check.sh — keeps docs/ops/merge-gates.md's pointers
# into .github/workflows/elixir.yml resolvable.
#
# THE FAILURE THIS PAYS. merge-gates.md is the card the routing table hands an
# agent who needs to verify a MERGE-AUTHORITY claim. Four of its pointers into
# elixir.yml were bare line numbers (`elixir.yml:510`, `:515`, `:667`, `:655`).
# Insertions above them slid every one by 80-95 lines: :510 now lands on a
# Paper-component golden-parity step, :667 on a `MIX_ENV: prod` line, :655 on a
# libvips install. Every SENTENCE stayed true; every POINTER to its evidence
# stopped resolving, so a reader sent to confirm "no `needs: mix-test` edge"
# read unrelated YAML instead. The pins have since been rewritten as job keys
# and quoted comment text — this guard is what stops them rotting back.
#
# WHY A GREP-ABLE ANCHOR AND NOT A REPAIRED LINE NUMBER. A line number is
# correct exactly once: the next insertion anywhere above it is silent, and
# nothing in CI reads it. `grep -n '^  mix-prod-compile:'` is correct always,
# and a RENAME — the one thing that can still break it — is loud here.
#
# WHAT IT CHECKS, three arms:
#   (1) every row of the ANCHORS table resolves on BOTH sides — the doc still
#       carries the phrase, and elixir.yml still carries the token that phrase
#       points at. A slid pin cannot fail this (that is the point); a renamed
#       job or a deleted comment can, and does.
#   (2) merge-gates.md carries no bare `elixir.yml:<N>` citation. The class the
#       guard exists to prevent cannot be reintroduced without reddening.
#   (3) the table is non-vacuous: a broken heredoc that walks ZERO rows would
#       otherwise print nothing and exit 0 — the shape that makes a gate lie.
#
# Usage:
#   scripts/merge-gates-elixir-anchor-check.sh             # check
#   scripts/merge-gates-elixir-anchor-check.sh --selftest  # prove it reds
# Exit codes: 0 pass · 1 an anchor failed · 2 bad usage.
#
# NOT YET WIRED INTO CI. doc-gates.yml already triggers on `**/*.md` AND on
# `.github/workflows/**`, which is exactly this guard's trigger pair, so the
# wiring is one step in its `Doc budgets + anchors` job. That edit belongs to
# the gates lane; this file is written to be dropped in unchanged.
#
# bash 3.2 compatible (stock macOS): no associative arrays, no mapfile.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(dirname "$(dirname "$SELF")")"

# Overridable so --selftest can point the arms at a mutated temp tree and prove
# they RED without planting anything in the real checkout.
DOC="${MG_ANCHOR_DOC:-$REPO_ROOT/docs/ops/merge-gates.md}"
WF="${MG_ANCHOR_WF:-$REPO_ROOT/.github/workflows/elixir.yml}"

# --- --selftest -------------------------------------------------------------
# Four arms. The first two are the pair that MATTERS, because together they
# state what an anchor buys over the line pin it replaced:
#   (a) RENAME the mix-prod-compile job key   -> must RED, naming the anchor.
#   (b) INSERT 40 blank lines above that job  -> must stay GREEN. This is the
#       exact mutation that broke all four old pins (an insertion above them).
#       A line-pin guard cannot tell (b) from a real break; this one is immune
#       to it by construction, which is the whole argument for the rewrite.
#   (c) plant a bare `elixir.yml:123` citation in the doc -> must RED.
#   (d) rewrite the doc sentence out from under a row     -> must RED, so the
#       table cannot end up guarding a pointer the doc no longer makes.
if [ "${1:-}" = "--selftest" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cp "$DOC" "$TMP/doc.md"
  cp "$WF" "$TMP/wf.yml"
  ST_FAIL=0

  run_arm() {  # run_arm <expect: pass|red> <label> <doc> <wf>
    expect="$1"; label="$2"; d="$3"; w="$4"
    if MG_ANCHOR_DOC="$d" MG_ANCHOR_WF="$w" bash "$SELF" >"$TMP/out.txt" 2>&1; then
      got=pass
    else
      got=red
    fi
    if [ "$got" = "$expect" ]; then
      echo "selftest ok:   $label -> $got (expected $expect)"
    else
      echo "selftest FAIL: $label -> $got (expected $expect)"
      sed 's/^/    | /' "$TMP/out.txt"
      ST_FAIL=1
    fi
  }

  # baseline: the real tree must pass, or every arm below is meaningless
  run_arm pass "baseline (unmutated tree)" "$TMP/doc.md" "$TMP/wf.yml"

  # (a) rename the anchored job key
  sed 's/^  mix-prod-compile:$/  mix-prod-compile-v2:/' "$TMP/wf.yml" > "$TMP/wf-renamed.yml"
  if cmp -s "$TMP/wf.yml" "$TMP/wf-renamed.yml"; then
    echo "selftest FAIL: arm (a) mutation did not APPLY — '^  mix-prod-compile:' not found"
    ST_FAIL=1
  else
    run_arm red "(a) job key renamed" "$TMP/doc.md" "$TMP/wf-renamed.yml"
  fi

  # (b) insert 40 blank lines at the top — the mutation that slid the old pins
  { for _ in $(seq 40); do echo ""; done; cat "$TMP/wf.yml"; } > "$TMP/wf-slid.yml"
  run_arm pass "(b) 40 lines inserted above every job (line pins would have slid)" \
    "$TMP/doc.md" "$TMP/wf-slid.yml"

  # (c) a bare line pin comes back into the doc
  { cat "$TMP/doc.md"; echo ""; echo "planted by --selftest: see elixir.yml:123 for the gate."; } > "$TMP/doc-pinned.md"
  run_arm red "(c) bare elixir.yml:<line> citation planted in the doc" "$TMP/doc-pinned.md" "$TMP/wf.yml"

  # (d) the doc sentence a row anchors on is rewritten away
  sed 's/the `mix-prod-compile:` job key/the prod-compile job/' "$TMP/doc.md" > "$TMP/doc-reworded.md"
  if cmp -s "$TMP/doc.md" "$TMP/doc-reworded.md"; then
    echo "selftest FAIL: arm (d) mutation did not APPLY — doc phrase not found"
    ST_FAIL=1
  else
    run_arm red "(d) doc phrase rewritten out from under a table row" "$TMP/doc-reworded.md" "$TMP/wf.yml"
  fi

  if [ "$ST_FAIL" -ne 0 ]; then
    echo "merge-gates-elixir-anchor-check --selftest: FAIL"
    exit 1
  fi
  echo "merge-gates-elixir-anchor-check --selftest: PASS (5 arms)"
  exit 0
elif [ -n "${1:-}" ]; then
  echo "usage: $(basename "$SELF") [--selftest]" >&2
  exit 2
fi

FAIL=0

# Rows are: <doc phrase> :: <elixir.yml grep -E pattern> :: <what it anchors>
# The doc phrase side matters as much as the workflow side: if someone rewrites
# the sentence, this table is stale and must be rewritten with it, rather than
# quietly guarding a pointer the doc no longer makes.
ROWS_EXPECTED=4
ROWS_WALKED=0

check_row() {
  phrase="$1"; pattern="$2"; label="$3"
  if ! grep -qF -- "$phrase" "$DOC"; then
    echo "FAIL: docs/ops/merge-gates.md no longer contains the anchoring phrase for $label:"
    echo "      \"$phrase\""
    echo "      Either the sentence was rewritten (update this table with it) or the"
    echo "      pointer was dropped (then drop the row)."
    FAIL=1
    return
  fi
  if ! grep -qE -- "$pattern" "$WF"; then
    echo "FAIL: $label — merge-gates.md points at it, but .github/workflows/elixir.yml"
    echo "      no longer matches: $pattern"
    echo "      The anchor was renamed or deleted. Re-point the doc at the new name;"
    echo "      do NOT replace it with a line number."
    FAIL=1
    return
  fi
  echo "ok:   $label resolves (doc phrase present; elixir.yml matches $pattern)"
}

while IFS='|' read -r phrase pattern label; do
  [ -z "$phrase" ] && continue
  ROWS_WALKED=$((ROWS_WALKED + 1))
  check_row "$phrase" "$pattern" "$label"
done <<'ANCHORS'
the `mix-prod-compile:` job key|^  mix-prod-compile:|the mix-prod-compile job key
the "NO needs: mix-test"|^ *# NO `needs: mix-test`\.|the "NO needs: mix-test" comment
the `elixir-gate` job's `needs:` line|^  elixir-gate:|the elixir-gate job key
the `elixir-gate` job's `needs:` comment block|^ *#.*`format` IS in `needs`|the "format IS in needs" comment
ANCHORS

if [ "$ROWS_WALKED" -ne "$ROWS_EXPECTED" ]; then
  echo "FAIL: the anchors table walked $ROWS_WALKED row(s), expected $ROWS_EXPECTED."
  echo "      Either the heredoc broke (a dark table verdicts on NOTHING and this"
  echo "      gate still exits 0), or you added/removed a row and must bump"
  echo "      ROWS_EXPECTED to match."
  FAIL=1
else
  echo "ok:   anchors table walked all $ROWS_WALKED row(s)"
fi

# Arm 2: no bare line pins may come back.
if grep -nE 'elixir\.yml:[0-9]+' "$DOC"; then
  echo "FAIL: docs/ops/merge-gates.md cites elixir.yml by LINE NUMBER (above)."
  echo "      That is the class this guard exists to prevent: an insertion"
  echo "      anywhere above the pin slides it silently and nothing in CI reads"
  echo "      it. Cite the job key or the quoted comment text instead, and add a"
  echo "      row to the ANCHORS table so it stays checked."
  FAIL=1
else
  echo "ok:   no bare elixir.yml:<line> citations in docs/ops/merge-gates.md"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "merge-gates-elixir-anchor-check: FAIL"
  exit 1
fi
echo "merge-gates-elixir-anchor-check: PASS"
exit 0
