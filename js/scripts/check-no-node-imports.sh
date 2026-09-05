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
set -euo pipefail

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
