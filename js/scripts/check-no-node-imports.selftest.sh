#!/usr/bin/env bash
# Selftest for check-no-node-imports.sh. Runs from anywhere:
#   bash js/scripts/check-no-node-imports.selftest.sh
#
# Every case builds a HERMETIC scratch corpus under mktemp -d and runs the guard
# with that scratch dir as the working directory. The repo's own tree is never
# written to, never moved.
#
# A red is only trusted once the plant is proved APPLIED: each planted shape is
# grepped back out of the file it was written to and must appear EXACTLY ONCE.
# A plant that silently failed to land would otherwise read as "guard is clean".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/check-no-node-imports.sh"

CORPUS=(
  "packages/core/src"
  "packages/nextjs/src/client"
  "packages/nextjs/src/server"
  "packages/nextjs/src/webhook"
  "packages/nextjs/src/draft-mode"
  "packages/nextjs/src/csp"
)
PLANT_DIR="packages/core/src"

PASS=0
FAIL=0

# Build a scratch corpus: every dir exists and holds one innocuous source file.
make_corpus() {
  local root
  root=$(mktemp -d)
  local d
  for d in "${CORPUS[@]}"; do
    mkdir -p "$root/$d"
    printf 'export const ok = 1\n' > "$root/$d/index.ts"
  done
  echo "$root"
}

# Run the guard with $1 as cwd. The exit code is taken from the guard ITSELF via
# command substitution — never through a pipe, whose status would be the last
# stage's, not the guard's.
run_guard() {
  local root="$1" out status
  set +e
  out=$(cd "$root" && bash "$GUARD" 2>&1)
  status=$?
  set -e
  GUARD_OUT="$out"
  return "$status"
}

assert_exit() {
  local label="$1" expected="$2" root="$3"
  local actual=0
  run_guard "$root" || actual=$?
  if [ "$actual" = "$expected" ]; then
    echo "  ok  — $label (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — $label"
    echo "    expected exit: $expected"
    echo "    actual exit:   $actual"
    echo "    guard output:  $GUARD_OUT"
    FAIL=$((FAIL + 1))
  fi
}

# Write a plant and PROVE it landed exactly once before any verdict is trusted.
plant() {
  local root="$1" anchor="$2" line="$3"
  local file="$root/$PLANT_DIR/planted.ts"
  printf '%s\n' "$line" > "$file"
  local n
  n=$(grep -cF "$anchor" "$file" || true)
  if [ "$n" != "1" ]; then
    echo "  FAIL — plant did not apply: anchor '$anchor' appears $n time(s) in $file (want exactly 1)"
    FAIL=$((FAIL + 1))
    return 1
  fi
  return 0
}

# --- CONTROL A: a whole, clean corpus is clean at exit 0 ---------------------
echo "case: CONTROL — clean corpus"
ROOT=$(make_corpus)
assert_exit "clean corpus exits 0" 0 "$ROOT"
rm -rf "$ROOT"

# --- CONTROL B: the shape the ORIGINAL guard already caught -----------------
echo "case: CONTROL — static prefixed import (caught before this change too)"
ROOT=$(make_corpus)
if plant "$ROOT" 'node:crypto' 'import c from "node:crypto";'; then
  assert_exit "static prefixed import exits 1" 1 "$ROOT"
fi
rm -rf "$ROOT"

# --- The four shapes that used to EVADE the guard ---------------------------
echo "case: evading shape B — dynamic import()"
ROOT=$(make_corpus)
if plant "$ROOT" 'await import' 'const c = await import("node:crypto");'; then
  assert_exit "await import(\"node:crypto\") exits 1" 1 "$ROOT"
fi
rm -rf "$ROOT"

echo "case: evading shape C — bare side-effect import"
ROOT=$(make_corpus)
if plant "$ROOT" 'import "node:crypto"' 'import "node:crypto";'; then
  assert_exit "bare side-effect import exits 1" 1 "$ROOT"
fi
rm -rf "$ROOT"

echo "case: evading shape D — createRequire"
ROOT=$(make_corpus)
if plant "$ROOT" 'createRequire' 'const c = createRequire(import.meta.url)("node:crypto");'; then
  assert_exit "createRequire exits 1" 1 "$ROOT"
fi
rm -rf "$ROOT"

echo "case: evading shape D2 — createRequire with an indirect specifier"
ROOT=$(make_corpus)
if plant "$ROOT" 'createRequire' 'const r = createRequire(import.meta.url); const c = r(name);'; then
  assert_exit "createRequire with a variable specifier still exits 1" 1 "$ROOT"
fi
rm -rf "$ROOT"

echo "case: evading shape E — legacy un-prefixed specifier"
ROOT=$(make_corpus)
if plant "$ROOT" 'from "crypto"' 'import crypto from "crypto";'; then
  assert_exit "legacy un-prefixed import exits 1" 1 "$ROOT"
fi
rm -rf "$ROOT"

echo "case: evading shape E2 — legacy un-prefixed require()"
ROOT=$(make_corpus)
if plant "$ROOT" "require('fs/promises')" "const fs = require('fs/promises');"; then
  assert_exit "legacy un-prefixed require exits 1" 1 "$ROOT"
fi
rm -rf "$ROOT"

# --- The corpus floor: a failed READ is never a pass ------------------------
echo "case: FLOOR A — a corpus dir moved aside"
ROOT=$(make_corpus)
mv "$ROOT/$PLANT_DIR" "$ROOT/packages/core/src-moved-aside"
assert_exit "missing corpus dir exits 3 (NOT 0, NOT 1)" 3 "$ROOT"
if run_guard "$ROOT"; then :; fi
case "$GUARD_OUT" in
  *"CANNOT READ: $PLANT_DIR missing"*)
    echo "  ok  — distinct line: CANNOT READ: $PLANT_DIR missing"; PASS=$((PASS + 1)) ;;
  *)
    echo "  FAIL — no distinct CANNOT READ line; got: $GUARD_OUT"; FAIL=$((FAIL + 1)) ;;
esac
rm -rf "$ROOT"

echo "case: FLOOR B — a corpus dir that exists but holds zero source files"
ROOT=$(make_corpus)
rm -f "$ROOT/$PLANT_DIR/index.ts"
printf 'not source\n' > "$ROOT/$PLANT_DIR/README.md"
assert_exit "zero-file corpus dir exits 3 (NOT 0, NOT 1)" 3 "$ROOT"
if run_guard "$ROOT"; then :; fi
case "$GUARD_OUT" in
  *"CANNOT READ: $PLANT_DIR holds zero"*)
    echo "  ok  — distinct line: CANNOT READ: $PLANT_DIR holds zero .ts/.tsx/.js/.mjs files"; PASS=$((PASS + 1)) ;;
  *)
    echo "  FAIL — no distinct zero-file line; got: $GUARD_OUT"; FAIL=$((FAIL + 1)) ;;
esac
rm -rf "$ROOT"

echo "case: FLOOR C — an entirely vanished corpus root"
ROOT=$(mktemp -d)
assert_exit "empty working directory exits 3 (NOT 0)" 3 "$ROOT"
rm -rf "$ROOT"

# NOTE: "the violation exit and the harness exit are distinct" is NOT asserted
# as its own case — comparing two literals is a tautology that would pass even
# if the guard collided them. The FLOOR cases above assert exit 3 and the shape
# cases assert exit 1 against the SAME guard, which is the real proof.

echo
echo "check-no-node-imports selftest: $((PASS + FAIL)) case(s) — passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
