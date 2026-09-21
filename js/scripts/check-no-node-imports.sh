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
# --selftest runs a CENSUS OF SHAPES in a THROWAWAY tree: it derives the
# expected shape list from the very "${SHAPES[@]}" array the scan uses (never a
# second hand-typed copy), gives EVERY declared shape a plant-and-disarm
# specimen pair, reds on any shape with no specimen (UNCOVERED) and on any
# specimen whose shape has been deleted (ORPHANED), and reports a denominator
# computed from the shape count. Plus a clean baseline and the THREE
# refused-to-measure corpora — no dirs at all (the floor literal), a dir holding
# zero source files, and one dir missing while the derived count still meets the
# floor (scan()'s own per-dir refusal, which the other two cannot reach).
#
# Usage: bash js/scripts/check-no-node-imports.sh            # the scan
#        bash js/scripts/check-no-node-imports.sh --selftest # prove it can lose
set -euo pipefail

# Absolute, captured BEFORE any cd: --selftest copies THIS file into each
# throwaway corpus so the assertions drive the shipping scan.
unset CDPATH
SELF="$(cd -P -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"

EXIT_VIOLATION=1
EXIT_CORPUS=3

# THE CORPUS IS DERIVED, NOT LISTED.
#
# This used to be a hand-written list of five @barkpark/nextjs subpath dirs
# (client, server, webhook, draft-mode, csp) plus packages/core/src. tsup builds
# EIGHT subpath source dirs under packages/nextjs/src, so `actions`, `preload`
# and `revalidate` were outside the scan — `actions` being the client bundle
# every consumer of `useOptimisticDocument` ships.
#
# MEASURED, not argued: planting `import { createHmac } from 'node:crypto'` in
# packages/nextjs/src/actions/index.ts left this script's report BYTE-IDENTICAL
# — same one pre-existing draft-mode violation, same "44 file(s)" — because the
# directory was never read. An enumeration cannot notice the entry it is missing,
# and the list had already fallen three dirs behind the build.
#
# So: read the tree. Every immediate subdirectory of packages/nextjs/src is a
# subpath source dir and is scanned; a new one is covered on its first run and
# nothing here needs editing.
#
# KNOWN SCOPE (stated, not hidden): the loose *.ts files directly under
# packages/nextjs/src (index.ts, metadata.ts, tag-prefix.ts) are barrels/helpers
# and stay out of the corpus, as they were before.
DIRS=("packages/core/src")
for _d in packages/nextjs/src/*/; do
  DIRS+=("${_d%/}")
done
unset _d

# The one expectation that does NOT come from the tree it measures. A derived
# corpus agrees with a gutted tree by construction: delete every subpath dir and
# the derivation happily scans one directory and calls it clean. The literal is
# what makes that a refusal. Below it is a HARNESS failure (exit 3), never a
# clean read; above it is fine and needs no edit (a new subpath is covered
# automatically) — only a DELIBERATE removal has to come here and lower it.
CORPUS_FLOOR=9
if [ "${#DIRS[@]}" -lt "$CORPUS_FLOOR" ]; then
  echo "CANNOT READ: the derived corpus is ${#DIRS[@]} dir(s), floor is $CORPUS_FLOOR" >&2
  echo "  Derived: ${DIRS[*]}" >&2
  echo "  A subpath source dir was renamed, moved or deleted, or this script is running" >&2
  echo "  from the wrong working directory (it must be js/). Refusing to scan a gutted" >&2
  echo "  corpus and report it clean." >&2
  exit "$EXIT_CORPUS"
fi

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
# is "<label>@@<extended regex>". ALL of them are DETECTED; none are out of
# scope, and --selftest proves each one bites by deriving its census from this
# array — adding a row here without a specimen reds the selftest.
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

# ── selftest: a CENSUS of SHAPES, not a hand-picked handful of specimens ──────
#
# Every arm builds a THROWAWAY corpus under mktemp -d — never the real js/ tree —
# copies THIS file in, and runs the copy with that tree as the working directory.
# The assertions therefore drive the shipping scan.
#
# WHY A CENSUS. The previous selftest planted five specimens covering three of
# the eight labels and printed "PASS (8/8)" — a number that came from the arm
# count, not from the shape set. Deleting five of the eight SHAPES entries left
# it green. So the expected shape list is now DERIVED, at run time, from the
# very "${SHAPES[@]}" array the scan uses; there is no second hand-typed copy of
# it to rot.
#
# THE SPECIMEN REGISTRY BELOW IS COVERAGE, NOT A MIRROR. It holds SOURCE LINES,
# never regexes, so it cannot agree with a rotted SHAPES entry by construction.
# It is reconciled against SHAPES IN BOTH DIRECTIONS:
#   • a shape with no specimen is reported UNCOVERED and reds — so adding a
#     shape without proving it cannot leave the score at full marks;
#   • a specimen whose shape has vanished is reported ORPHANED and reds — so
#     deleting a shape from the scan reds instead of shrinking the census.
#
# EVERY SHAPE GETS A PLANT-AND-DISARM PAIR, not a mere mention:
#   PLANT   — the specimen in a clean corpus must be caught, at exit 1, under
#             that shape's own label.
#   DISARM  — with that one SHAPES line deleted from the COPY, the same
#             specimen must sail through at exit 0. Without this half, a PLANT
#             arm can be green because some OTHER shape caught the line, and a
#             neutered regex would never be noticed.
#
# EVERY PLANT IS VERIFIED TO HAVE LANDED before its probe runs. A specimen that
# silently failed to write, or a mutation whose anchor did not match, passes
# while testing nothing — that is the exact defect class this guard exists for.

# One planted source line per shape label, "<label>::<line>". Deliberately NOT
# written with the SHAPES separator (@@) or its leading-quote indentation, so a
# disarm anchor can never match a registry row instead of the rule it targets.
SPECIMENS=(
  'static-prefixed::import c from "node:crypto";'
  'require-prefixed::const c = require("node:crypto");'
  'dynamic-import-prefixed::const c = await import("node:crypto");'
  'bare-side-effect-prefixed::import "node:crypto";'
  'create-require::const req = createRequire(import.meta.url);'
  'legacy-unprefixed-from::import c from "crypto";'
  'legacy-unprefixed-call::const c = require("crypto");'
  'legacy-unprefixed-bare::import "crypto";'
)

specimen_line_for() {
  local want="$1" entry
  for entry in "${SPECIMENS[@]}"; do
    if [ "${entry%%::*}" = "$want" ]; then printf '%s\n' "${entry#*::}"; return 0; fi
  done
  return 1
}

selftest() {
  local tmp bad=0 ran=0 total rc anchor shape label line entry
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say() { ran=$((ran + 1)); if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi; }
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

  # Delete exactly ONE SHAPES entry from the probe copy, by label. Anchored on
  # the SHAPES row alone: a bare label match would also hit the registry rows
  # and the prose above, and mutate something other than the rule.
  disarm_shape() {
    local lbl="$1"
    anchor="^  \"${lbl}@@"
    plant_check "the disarm anchor for $lbl did not match EXACTLY ONCE" \
      test "$(grep -cE "$anchor" "$tmp/t/probe.sh")" -eq 1
    sed -E "/$anchor/d" "$tmp/t/probe.sh" > "$tmp/mut" && mv "$tmp/mut" "$tmp/t/probe.sh"
    plant_check "the disarm of $lbl produced no diff" \
      test "$(grep -cE "$anchor" "$tmp/t/probe.sh")" -eq 0
  }

  # The census is sized off the SHAPES array itself — four fixed arms plus a
  # plant and a disarm for every shape the scan declares.
  total=$((4 + 2 * ${#SHAPES[@]}))

  echo "check-no-node-imports --selftest (throwaway corpora under $tmp)"
  echo "  census: ${#SHAPES[@]} shape(s) declared by SHAPES, ${#SPECIMENS[@]} specimen(s) registered"

  # 0a. COVERAGE — every declared shape must have a specimen. A new shape with
  #     no plant-and-disarm pair cannot leave the score at full marks.
  for shape in "${SHAPES[@]}"; do
    label="${shape%%@@*}"
    if ! specimen_line_for "$label" >/dev/null; then
      echo "  FAIL  UNCOVERED SHAPE: SHAPES declares '$label' but no specimen proves it bites"
      bad=$((bad + 1))
    fi
  done

  # 0b. ORPHANS — every registered specimen must still have a shape. Deleting a
  #     detection shape from the scan reds HERE instead of quietly shrinking the
  #     census to match the damage.
  for entry in "${SPECIMENS[@]}"; do
    label="${entry%%::*}"
    if ! printf '%s\n' "${SHAPES[@]}" | grep -q "^${label}@@"; then
      echo "  FAIL  ORPHANED SPECIMEN: '$label' has a specimen but SHAPES no longer declares it"
      bad=$((bad + 1))
    fi
  done

  # 1. SILENT ARM — a clean corpus passes, and states its sample size.
  fresh
  rc="$(probe)"
  if [ "$rc" -eq 0 ] && grep -q "check-no-node-imports: clean (" "$tmp/out"; then
    say "a clean corpus -> exit 0, and states how many files it scanned" 0
  else
    say "a clean corpus -> exit 0 (got $rc)" 1
    sed 's/^/        /' "$tmp/out"
  fi

  # 2. THE PLANT-AND-DISARM PAIR, ONCE PER DECLARED SHAPE.
  for shape in "${SHAPES[@]}"; do
    label="${shape%%@@*}"
    line="$(specimen_line_for "$label")" || continue   # already counted as UNCOVERED

    # PLANT: the specimen is caught, at exit 1, under this shape's own label.
    fresh
    specimen "$line"
    rc="$(probe)"
    if [ "$rc" -eq 1 ] && grep -q "FAIL: $label " "$tmp/out"; then
      say "PLANT  $label: '$line' -> exit 1 ($label)" 0
    else
      say "PLANT  $label: '$line' -> exit 1 ($label) (got $rc)" 1
      sed 's/^/        /' "$tmp/out"
    fi

    # DISARM: with that one shape deleted, the same specimen is ACCEPTED. This
    # is what makes the PLANT arm load-bearing rather than incidental.
    fresh
    disarm_shape "$label"
    specimen "$line"
    rc="$(probe)"
    if [ "$rc" -eq 0 ]; then
      say "DISARM $label: with the shape deleted, its specimen is ACCEPTED (the PLANT arm is load-bearing)" 0
    else
      say "DISARM $label: with the shape deleted, its specimen is ACCEPTED (got $rc — the PLANT arm proves nothing)" 1
      sed 's/^/        /' "$tmp/out"
    fi
  done

  # 3. REFUSED TO MEASURE — the whole corpus is gone. This is the mode that used
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

  # 4. REFUSED TO MEASURE — the dirs exist but hold nothing scannable. A rename
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

  # 5. REFUSED TO MEASURE — ONE corpus dir is gone while the DERIVED COUNT still
  #    meets the floor. This is a third, distinct refusal path and arms 3 and 4
  #    are both blind to it: arm 3 removes the whole tree, which trips the
  #    CORPUS_FLOOR literal before scan() ever runs, and arm 4 leaves the
  #    directory in place holding no source files. Only `packages/core/src` can
  #    reach this branch, because it is the one DIRS entry that is a literal
  #    rather than a glob result — delete it and the derivation still yields 9
  #    entries, the floor is satisfied, and the refusal has to come from scan()'s
  #    own per-dir `! -d` test.
  #
  #    MEASURED, not argued: replacing that test's body with `continue` — the
  #    exact pre-fix defect, a vanished dir read as clean — left this selftest at
  #    PASS (19/19). The arm below is what that mutation now reds, and it is the
  #    one assertion the deleted js/scripts/check-no-node-imports.selftest.sh
  #    carried that nothing else here did.
  fresh
  rm -rf "$tmp/t/packages/core/src"
  plant_check "the single-dir removal did not land" test ! -d "$tmp/t/packages/core/src"
  rc="$(probe)"
  if [ "$rc" -eq 3 ] && grep -q "CANNOT READ: packages/core/src missing" "$tmp/out" \
     && ! grep -q "floor is" "$tmp/out"; then
    say "ONE corpus dir missing while the count still meets the floor -> exit 3 from scan()'s own per-dir refusal" 0
  else
    say "ONE corpus dir missing while the count still meets the floor -> exit 3 naming that dir (got $rc)" 1
    sed 's/^/        /' "$tmp/out"
  fi

  echo ""
  # The denominator is DERIVED from SHAPES, and a skipped arm is not a passed
  # one: `ran` must reach the planned total or the run is short and reds.
  if [ "$bad" -eq 0 ] && [ "$ran" -eq "$total" ]; then
    echo "check-no-node-imports --selftest: PASS ($ran/$total)"; return 0
  fi
  if [ "$ran" -ne "$total" ]; then
    echo "check-no-node-imports --selftest: SHORT RUN — $ran of $total planned case(s) actually ran"
  fi
  echo "check-no-node-imports --selftest: FAILED ($bad case(s), $ran/$total ran)"; return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  "")         scan ;;
  *)          echo "usage: bash js/scripts/check-no-node-imports.sh [--selftest]" >&2; exit 64 ;;
esac
