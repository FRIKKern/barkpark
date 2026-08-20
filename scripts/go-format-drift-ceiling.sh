#!/usr/bin/env bash
# go-format-drift-ceiling.sh — the Go (gofmt) shrink-only drift ceiling
# (honest-gates, Go side of scripts/format-drift-ceiling.sh's Elixir ratchet).
#
# WHY THIS EXISTS. The `Go format` workflow's `gofmt -l` step is ADVISORY
# (continue-on-error), so gofmt drift can accumulate forever — the census went
# 12 → 30 files under it. This gate is the counter-ratchet: a BLOCKING job whose
# ONLY job is to refuse NEW drift. It reads a committed roster of the exact files
# that were drifted when the ratchet landed (`.go-format-drift-ceiling`) and FAILS
# — naming the file — the moment any *off-roster* Go file is not gofmt-clean, or a
# rostered file has been cleaned but not pruned from the roster (shrink-only).
#
# TWO NON-OBVIOUS LESSONS carried verbatim from the Elixir build:
#   1. `continue-on-error` is a JOB-level setting — it neutralises EVERY step in
#      its job. This gate MUST run as its OWN job (never a step inside the
#      advisory gofmt job), or it silently becomes unable to fail — the exact
#      disease it exists to stop. (Wiring lives in .github/workflows/go-format.yml.)
#   2. Do NOT trust an empty result. `gofmt -l` printing nothing is
#      indistinguishable from success unless we separately confirm the tool ran
#      and the scanned file set was non-empty. A toolchain/checkout failure that
#      scans zero files would otherwise report a vacuous "clean". This gate
#      asserts the scanned population is plausible (>= GO_CEILING_MIN_FILES) and
#      FAILS closed if gofmt is missing or nothing was scanned.
#
# USAGE:
#   bash scripts/go-format-drift-ceiling.sh            # enforce the ceiling
#   bash scripts/go-format-drift-ceiling.sh --selftest # prove the gate can fail
#
# Overrides (used by --selftest to drive temp trees):
#   GO_CEILING_ROOT       repo root to scan          (default: git toplevel)
#   GO_CEILING_ROSTER     roster path                (default: $ROOT/.go-format-drift-ceiling)
#   GO_CEILING_MIN_FILES  plausibility floor         (default: 300)
set -euo pipefail

# ── core ─────────────────────────────────────────────────────────────────────
# enumerate_go_files ROOT — tracked *.go (git) minus vendor/, or a filesystem
# walk when ROOT is not a git tree (the --selftest temp dirs). One file per line.
enumerate_go_files() {
  local root="$1"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" ls-files '*.go' | grep -v '^vendor/' || true
  else
    ( cd "$root" && find . -name '*.go' -not -path './vendor/*' | sed 's#^\./##' | sort )
  fi
}

# run_ceiling ROOT ROSTER MIN_FILES — returns 0 clean, 1 drift/failure. Prints a
# verdict. Fails closed on a zero/short scan (lesson 2) BEFORE trusting gofmt.
run_ceiling() {
  local root="$1" roster_path="$2" min_files="$3"

  command -v gofmt >/dev/null 2>&1 || { echo "FAIL: gofmt not found on PATH — cannot scan, refusing to report clean"; return 1; }

  local files; files="$(enumerate_go_files "$root")"
  local count; count="$(printf '%s\n' "$files" | grep -c . || true)"
  if [ "$count" -lt "$min_files" ]; then
    echo "FAIL: scanned only $count Go files (floor: $min_files) — a short/zero scan is NOT a clean tree."
    echo "      Discovery or toolchain failure suspected; refusing a vacuous green."
    return 1
  fi

  # current drift = gofmt-dirty files, repo-relative, sorted.
  local dirty; dirty="$( cd "$root" && printf '%s\n' "$files" | xargs gofmt -l 2>/dev/null | sed 's#^\./##' | sort -u || true )"

  # roster = grandfathered drift (comments/blank lines ignored), sorted.
  local roster=""
  [ -f "$roster_path" ] && roster="$(grep -vE '^\s*(#|$)' "$roster_path" | sort -u || true)"

  # set difference over sorted, non-empty-line inputs.
  _sorted() { printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | sort -u; }
  # new drift = dirty ∖ roster → the ratchet break.
  local newdrift; newdrift="$(comm -23 <(_sorted "$dirty") <(_sorted "$roster"))"
  # stale roster = roster ∖ dirty → cleaned but not pruned (shrink-only demands a prune).
  local stale; stale="$(comm -13 <(_sorted "$dirty") <(_sorted "$roster"))"

  local rc=0
  if [ -n "$(printf '%s' "$newdrift" | tr -d '[:space:]')" ]; then
    echo "FAIL: NEW gofmt drift in file(s) not on the ceiling roster:"
    printf '%s\n' "$newdrift" | sed 's/^/  - /'
    echo "  Fix: gofmt -w <file>   (drift must SHRINK, never grow past the roster)"
    rc=1
  fi
  if [ -n "$(printf '%s' "$stale" | tr -d '[:space:]')" ]; then
    echo "FAIL: roster lists file(s) that are now gofmt-clean — shrink-only ratchet requires pruning them from $roster_path:"
    printf '%s\n' "$stale" | sed 's/^/  - /'
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    local rostered; rostered="$(printf '%s\n' "$roster" | grep -c . || true)"
    echo "OK: $count Go files scanned; 0 off-roster drift; roster holds $rostered grandfathered file(s)."
  fi
  return "$rc"
}

# ── self-test (tripwire): prove the gate REDs on drift and on a vacuous zero ──
selftest() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local fails=0

  # Case A — a misformatted off-roster file MUST fail, naming the file.
  local a="$tmp/A"; mkdir -p "$a"
  printf 'package p\n\nvar M = map[string]int{\n"a": 1,\n"bb": 2,\n}\n' > "$a/bad.go"
  : > "$a/.go-format-drift-ceiling"  # empty roster → zero tolerance
  local a_out a_rc
  a_out="$(run_ceiling "$a" "$a/.go-format-drift-ceiling" 1 2>&1)" && a_rc=0 || a_rc=$?
  if [ "$a_rc" -eq 0 ]; then
    echo "SELFTEST FAIL (A): a drifted off-roster file did NOT red the gate"; fails=1
  elif printf '%s' "$a_out" | grep -q 'bad.go'; then
    echo "SELFTEST ok (A): drifted file reds the gate, named"
  else
    echo "SELFTEST FAIL (A): reddened but did not name bad.go"; fails=1
  fi

  # Case B — a gofmt-clean file with an empty roster MUST pass.
  local b="$tmp/B"; mkdir -p "$b"
  printf 'package p\n\nvar X = 1\n' > "$b/good.go"; gofmt -w "$b/good.go"
  : > "$b/.go-format-drift-ceiling"
  if run_ceiling "$b" "$b/.go-format-drift-ceiling" 1 >/dev/null 2>&1; then
    echo "SELFTEST ok (B): clean tree passes"
  else
    echo "SELFTEST FAIL (B): a clean tree was rejected"; fails=1
  fi

  # Case C — a zero/short scan MUST fail closed (lesson 2), never report clean.
  local c="$tmp/C"; mkdir -p "$c"; : > "$c/.go-format-drift-ceiling"
  if run_ceiling "$c" "$c/.go-format-drift-ceiling" 1 >/dev/null 2>&1; then
    echo "SELFTEST FAIL (C): an empty scan reported clean (vacuous green)"; fails=1
  else
    echo "SELFTEST ok (C): empty/short scan fails closed"
  fi

  # Case D — a rostered-but-clean file MUST fail (shrink-only prune enforcement).
  local d="$tmp/D"; mkdir -p "$d"
  printf 'package p\n\nvar Y = 2\n' > "$d/clean.go"; gofmt -w "$d/clean.go"
  printf 'clean.go\n' > "$d/.go-format-drift-ceiling"
  if run_ceiling "$d" "$d/.go-format-drift-ceiling" 1 >/dev/null 2>&1; then
    echo "SELFTEST FAIL (D): a stale roster entry did NOT red the gate"; fails=1
  else
    echo "SELFTEST ok (D): stale roster entry reds (shrink-only prune enforced)"
  fi

  if [ "$fails" -ne 0 ]; then echo "SELFTEST: FAILURES ABOVE"; return 1; fi
  echo "SELFTEST: all cases passed — the gate can fail on drift and on a vacuous zero"
}

# ── entry ────────────────────────────────────────────────────────────────────
# Refuse an argument this gate does not understand. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "go-format-drift-ceiling: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

ROOT="${GO_CEILING_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROSTER="${GO_CEILING_ROSTER:-$ROOT/.go-format-drift-ceiling}"
MIN_FILES="${GO_CEILING_MIN_FILES:-300}"
run_ceiling "$ROOT" "$ROSTER" "$MIN_FILES"
