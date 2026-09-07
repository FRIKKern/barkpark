#!/usr/bin/env bash
# Edge-safety gate: no Node builtin may be reachable from edge-reachable code
# paths (see the ADR-002 edge-contract row in docs/decisions/deferred.md).
#
# Run with the repo's js/ directory as the working directory (js-tests.yml
# sets defaults.run.working-directory: js).
#
# EXIT CODES — a failed READ must never be byte-identical to a clean read:
#   0  clean: every corpus dir was read, held source files, and matched nothing.
#   1  violation(s) found. ADVISORY: the js-tests.yml step splits on this
#      script's exit status — 1 emits a ::warning and the step PASSES, 3 reds it
#      (ADR-002 conflict: draft-mode/ imports node:crypto). Do NOT re-add
#      continue-on-error to that step; it would swallow exit 3 too.
#   3  HARNESS FAILURE: a corpus dir is missing, or exists but holds zero
#      scannable source files, or the Node builtin list could not be derived.
#      A vanished corpus used to `continue` and print "clean" at exit 0 — a
#      directory rename, a package move or a wrong working-directory disarmed
#      the gate completely while PRINTING SUCCESS.
#  64 bad usage.
#
# --selftest plants the five specimens from the row that filed this guard (a
# clean baseline, a dynamic import, a bare side-effect import, a static import
# and a re-export) plus an empty corpus, in a THROWAWAY tree, and includes a
# mutation arm that disarms a shape to prove the specimen arms can fail.
#
# Usage: bash js/scripts/check-no-node-imports.sh            # the scan
#        bash js/scripts/check-no-node-imports.sh --selftest # prove it can lose
set -euo pipefail

# Absolute, captured BEFORE any cd: --selftest copies THIS file into each
# throwaway corpus so the assertions drive the shipping scan.
SELF="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"

EXIT_VIOLATION=1
EXIT_CORPUS=3

DIRS=(
  "packages/core/src"
  "packages/nextjs/src/client"
  "packages/nextjs/src/server"
  "packages/nextjs/src/webhook"
  "packages/nextjs/src/draft-mode"
  "packages/nextjs/src/csp"
)

# The legacy un-prefixed specifier set (`import crypto from "crypto"`) needs the
# Node builtin list. It is DERIVED at run time from the running Node, never
# hand-typed: a hand-typed list silently rots every time Node adds a builtin.
if ! command -v node >/dev/null 2>&1; then
  echo "CANNOT READ: node is not on PATH — the Node builtin list cannot be derived" >&2
  exit "$EXIT_CORPUS"
fi
BUILTINS=$(node -e '
  const m = require("module").builtinModules
    .filter(n => !n.startsWith("node:") && !n.startsWith("_"));
  // Longest first so alternation prefers "fs/promises" over "fs".
  m.sort((a, b) => b.length - a.length);
  console.log(m.join("|"));
') || {
  echo "CANNOT READ: could not derive the Node builtin list from node -e" >&2
  exit "$EXIT_CORPUS"
}
if [ -z "$BUILTINS" ]; then
  echo "CANNOT READ: the derived Node builtin list is empty" >&2
  exit "$EXIT_CORPUS"
fi

# Every shape that reaches a Node builtin from edge-reachable code. Each entry
# is "<label>@@<extended regex>". All six are DETECTED; none are out of scope.
#
#   createRequire is flagged on the CALL, not on a `node:` argument: its only
#   purpose in ESM is to reach CJS/builtins, and the specifier may be a
#   variable, so matching the argument would be defeatable by one indirection.
#
# KNOWN LIMIT (deliberate, not a scope exclusion): this is a textual grep, so a
# `node:` specifier assembled at run time from string fragments, and a builtin
# name appearing inside a comment, are respectively missed and over-reported.
# An import-graph analyser is the durable answer; this gate is the cheap floor.
SHAPES=(
  "static-prefixed@@from[[:space:]]*['\"]node:"
  "require-prefixed@@require[[:space:]]*\([[:space:]]*['\"]node:"
  "dynamic-import-prefixed@@import[[:space:]]*\([[:space:]]*['\"]node:"
  "bare-side-effect-prefixed@@^[[:space:]]*import[[:space:]]+['\"]node:"
  "create-require@@createRequire[[:space:]]*\("
  "legacy-unprefixed-from@@from[[:space:]]*['\"](${BUILTINS})['\"]"
  "legacy-unprefixed-call@@(require|import)[[:space:]]*\([[:space:]]*['\"](${BUILTINS})['\"]"
  "legacy-unprefixed-bare@@^[[:space:]]*import[[:space:]]+['\"](${BUILTINS})['\"]"
)

# The scan itself. Reads the corpus RELATIVE TO THE CURRENT DIRECTORY, which is
# what lets --selftest drive this exact code path over a throwaway tree instead
# of a second implementation that could agree with the first while both are
# wrong.
scan() {
  local dir files shape label regex
  HITS=0
  SCANNED=0
  for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
      echo "CANNOT READ: $dir missing" >&2
      exit "$EXIT_CORPUS"
    fi
    files=$(find "$dir" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.mjs' \) | wc -l | tr -d '[:space:]')
    if [ "$files" -eq 0 ]; then
      echo "CANNOT READ: $dir holds zero .ts/.tsx/.js/.mjs files" >&2
      exit "$EXIT_CORPUS"
    fi
    SCANNED=$((SCANNED + files))
    for shape in "${SHAPES[@]}"; do
      label="${shape%%@@*}"
      regex="${shape#*@@}"
      if grep -RnE --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' "$regex" "$dir"; then
        echo "FAIL: $label reaches a Node builtin in $dir"
        HITS=$((HITS + 1))
      fi
    done
  done

  if [ "$HITS" -gt 0 ]; then
    echo "check-no-node-imports: $HITS violation(s) across $SCANNED file(s)"
    exit "$EXIT_VIOLATION"
  fi
  echo "check-no-node-imports: clean ($SCANNED file(s) scanned)"
}

# ── selftest: the five planted specimens, plus the proof this can LOSE ────────
#
# Every arm builds a THROWAWAY corpus under mktemp -d — never the real js/ tree —
# copies THIS file in, and runs the copy with that tree as the working directory.
# The assertions therefore drive the shipping scan.
#
# EVERY PLANT IS VERIFIED TO HAVE LANDED before its probe runs. A specimen that
# silently failed to write, or a mutation whose anchor did not match, passes
# while testing nothing — that is the exact defect class this guard exists for.
#
# ARM 8 IS THE ONE THAT MATTERS: it DISARMS a shape and asserts the matching
# specimen is then ACCEPTED. Without it, arms 2-5 could be green because the
# harness cannot fail rather than because the rule bites.
selftest() {
  local tmp bad=0 rc anchor
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi; }
  # Takes a CONDITION, not an exit status: `cmd; plant_check msg $?` cannot work
  # under `set -e`, which kills the shell before $? is ever read.
  plant_check() { local msg="$1"; shift; if "$@"; then :; else echo "  FAIL  PLANT CHECK: $msg"; bad=$((bad + 1)); fi; }

  # A clean corpus: every DIRS entry present, each holding one blameless file.
  fresh() {
    local d
    rm -rf "$tmp/t"
    mkdir -p "$tmp/t"
    for d in "${DIRS[@]}"; do
      mkdir -p "$tmp/t/$d"
      printf 'export const ok = 1;\n' > "$tmp/t/$d/clean.ts"
    done
    cp "$SELF" "$tmp/t/probe.sh"
  }

  # Runs the COPY with the throwaway tree as cwd. Output is captured so the
  # scan's own grep hits do not drown the tally.
  probe() { ( cd "$tmp/t" && bash ./probe.sh ) > "$tmp/out" 2>&1; echo $?; }

  # Plant one specimen line and assert it is on disk before probing.
  specimen() {
    local line="$1" target="$tmp/t/packages/core/src/specimen.ts"
    printf '%s\n' "$line" > "$target"
    plant_check "specimen not on disk: $line" grep -qF -- "$line" "$target"
  }

  # One violation arm: plant, probe, expect exit 1 and the named shape label.
  violates() {
    local label="$1" line="$2" desc="$3"
    fresh
    specimen "$line"
    rc="$(probe)"
    if [ "$rc" -eq 1 ] && grep -q "FAIL: $label " "$tmp/out"; then
      say "$desc -> exit 1 ($label)" 0
    else
      say "$desc -> exit 1 ($label) (got $rc)" 1
      sed 's/^/        /' "$tmp/out"
    fi
  }

  echo "check-no-node-imports --selftest (throwaway corpora under $tmp)"

  # 1. SILENT ARM — a clean corpus passes, and states its sample size.
  fresh
  rc="$(probe)"
  if [ "$rc" -eq 0 ] && grep -q "check-no-node-imports: clean (" "$tmp/out"; then
    say "a clean corpus -> exit 0, and states how many files it scanned" 0
  else
    say "a clean corpus -> exit 0 (got $rc)" 1
    sed 's/^/        /' "$tmp/out"
  fi

  # 2-5. THE FOUR SPECIMENS THE ROW PLANTED. Two of them (dynamic import and the
  #      bare side-effect import) were the shapes that slipped through silently.
  violates "dynamic-import-prefixed"    'const c = await import("node:crypto");' \
           "a dynamic import of a node: builtin"
  violates "bare-side-effect-prefixed"  'import "node:crypto";' \
           "a bare side-effect import of a node: builtin"
  violates "static-prefixed"            'import c from "node:crypto";' \
           "a static default import of a node: builtin"
  violates "static-prefixed"            'export { randomUUID } from "node:crypto";' \
           "a re-export from a node: builtin"

  # 6. REFUSED TO MEASURE — the whole corpus is gone. This is the mode that used
  #    to print "clean" at exit 0, so it must NEVER be green.
  fresh
  rm -rf "$tmp/t/packages"
  plant_check "the corpus was not actually removed" test ! -d "$tmp/t/packages"
  rc="$(probe)"
  if [ "$rc" -eq 3 ] && grep -q "CANNOT READ" "$tmp/out"; then
    say "an EMPTY corpus (no dirs at all) -> exit 3, never a green" 0
  else
    say "an EMPTY corpus (no dirs at all) -> exit 3 (got $rc)" 1
    sed 's/^/        /' "$tmp/out"
  fi

  # 7. REFUSED TO MEASURE — the dirs exist but hold nothing scannable. A rename
  #    that leaves the directory behind is indistinguishable from a clean read
  #    unless this arm holds.
  fresh
  rm -f "$tmp/t/packages/core/src/clean.ts"
  plant_check "the emptied-dir plant did not land" test ! -e "$tmp/t/packages/core/src/clean.ts"
  rc="$(probe)"
  if [ "$rc" -eq 3 ] && grep -q "holds zero" "$tmp/out"; then
    say "a corpus dir with zero source files -> exit 3, never a green" 0
  else
    say "a corpus dir with zero source files -> exit 3 (got $rc)" 1
    sed 's/^/        /' "$tmp/out"
  fi

  # 8. THE BITE PROOF — disarm the dynamic-import shape in the COPY and the
  #    specimen from arm 2 must sail through at exit 0. If this arm ever reports
  #    "still caught", arm 2 is not measuring what its label claims.
  fresh
  # Anchored on the SHAPES entry alone. A bare label match would also hit these
  # very lines (the selftest names the label it disarms), delete them from the
  # copy, and mutate something other than the rule.
  anchor='^  "dynamic-import-prefixed@@'
  plant_check "the disarm anchor did not match EXACTLY ONCE" \
    test "$(grep -cE "$anchor" "$tmp/t/probe.sh")" -eq 1
  sed -E "/$anchor/d" "$tmp/t/probe.sh" > "$tmp/mut" && mv "$tmp/mut" "$tmp/t/probe.sh"
  plant_check "the disarm produced no diff" \
    test "$(grep -cE "$anchor" "$tmp/t/probe.sh")" -eq 0
  specimen 'const c = await import("node:crypto");'
  rc="$(probe)"
  if [ "$rc" -eq 0 ]; then
    say "MUTATION: with the dynamic-import shape deleted, the specimen is ACCEPTED (arm 2 is load-bearing)" 0
  else
    say "MUTATION: with the dynamic-import shape deleted, the specimen is ACCEPTED (got $rc — arm 2 proves nothing)" 1
    sed 's/^/        /' "$tmp/out"
  fi

  echo ""
  if [ "$bad" -eq 0 ]; then echo "check-no-node-imports --selftest: PASS (8/8)"; return 0; fi
  echo "check-no-node-imports --selftest: FAILED ($bad case(s))"; return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  "")         scan ;;
  *)          echo "usage: bash js/scripts/check-no-node-imports.sh [--selftest]" >&2; exit 64 ;;
esac
