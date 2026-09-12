#!/usr/bin/env bash
#
# web-path-escape-check.sh — the web/ gate's path set, and the ratchet that
# proves the set still covers everything the web/ gate READS.
#
# WHY THIS EXISTS (pds-bl-w48-web-gate-cannot-block-and-greens-vacuously)
# ----------------------------------------------------------------------
# .github/workflows/ci.yml carried a WORKFLOW-LEVEL `on: … paths:` filter on
# BOTH arms until this slice. A workflow-level filter emits NO workflow run and
# NO check run at all on a non-matching head, so the one real gate that workflow
# publishes — `web/ typecheck + unit tests + lint` — was ABSENT on every PR that
# touched no web/ path. An absent required context reports `is expected.`
# forever and deadlocks the PR, which is why .github/required-checks.json holds
# that name in `.exclusions` with an `S4 PATHS-FILTERED` reason instead of in
# the required set (added 2026-09-07, task-6c8a76a6f6196dfd). The gate could not
# be required. The fix is the house skip shim (cloud.yml, console-harness.yml,
# elixir.yml, security.yml): the filter moves DOWN, from the trigger to a
# job-level `if:` fed by an always-running dispatcher, and this file is the
# dispatcher's declaration.
#
# ONE DECLARATION. ci.yml never hand-writes a path list for its `pull_request`
# work: it shells `--match web` here. That is the same rule cloud.yml and
# console-harness.yml follow, and for the same reason — a set declared twice
# drifts in silence, and the half that drifts is the half nobody re-reads.
#
# WHAT THE RATCHET MEASURED, 2026-09-11 (the reason it is not ceremony)
# --------------------------------------------------------------------
# The old trigger set was `web/**`, `lighthouserc.json`, `.github/workflows/ci.yml`.
# Re-deriving web/'s real reads from the working tree found FIVE resolved reads
# across FOUR trees (`--list-reads`, 2026-09-11), and THREE of those four trees
# were outside that set:
#
#   js/packages/core                     web/package.json `file:` dependency
#   js/packages/react                    web/package.json `file:` dependency
#   scripts/node-test-floor.mjs          web/package.json "test" script
#   js/packages/create-barkpark-app/…    web/__tests__/template-*.test.ts read
#     templates/_shared/…                the template SOURCE and assert on it
#
# So an edit to a starter template, or to the node --test floor, dispatched NO
# web job at all, while the tests that pin those very files live in web/. The
# declared set below covers all four; this script FAILS when a fifth appears
# without being declared.
#
# HOW A READ IS RESOLVED — three arms, all live in this tree
# ----------------------------------------------------------
#   1. `file:` DEPENDENCIES in web/package.json. `"@barkpark/core":
#      "file:../js/packages/core"` — the package is BUILT from source by the
#      job (`pnpm --filter @barkpark/core build`), so its source is an input to
#      web/'s typecheck, not a pinned artifact.
#   2. `../`-ESCAPING literals in web/package.json "scripts". The "test" script
#      runs `node ../scripts/node-test-floor.mjs`; a change to that floor
#      changes what `pnpm run test` asserts.
#   3. `../`-ESCAPING string literals in web/**/*.{ts,tsx,js,mjs}. The two
#      template tests read the starter templates by relative path.
#
# EXISTENCE IS THE FILTER, exactly as in go-path-escape-check.sh: a literal that
# resolves to nothing on disk is a fixture, a 404 probe or a table entry, not a
# dependency. Reads resolving back INSIDE web/ are dropped — `web/**` already
# covers them and they are not cross-tree by definition — as are reads under
# node_modules/ (installed artifacts, never a changed-file path) and .git/.
#
# USAGE
#   web-path-escape-check.sh                 # the ratchet (CI)
#   web-path-escape-check.sh --list-reads    # the resolved census
#   web-path-escape-check.sh --print-set     # the declared globs
#   web-path-escape-check.sh --match web     # changed paths on stdin -> true|false
#   web-path-escape-check.sh --selftest      # prove the ratchet can FAIL
#
# Env, for proof runs only (neither can weaken a real run — both retarget the
# tree that is READ, and the selftest is what uses them):
#   WEB_PATH_ESCAPE_ROOT   scan another tree
#   WEB_PATH_ESCAPE_SET    read the declared set from a file, one glob per line
#
# EXIT: 0 every resolved read is declared · 1 a read escapes the set ·
#       2 refused to measure (bad usage, unreadable tree, census below floor).
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${WEB_PATH_ESCAPE_ROOT:-$(cd -- "$SELF_DIR/.." && pwd)}"

# ---------------------------------------------------------------------------
# THE DECLARED SET — the one place the web path set is written
# ---------------------------------------------------------------------------
# GitHub path-glob syntax, because that is the syntax every other path set in
# this repo is written in and the matcher below is character-for-character
# go-path-escape-check.sh's g2e().
#
# Each row carries WHY it is here; a row with no reason is a row nobody can
# retire — so the reason is a `#` line directly above its glob, and the SAME
# comment filter runs over both sources (this heredoc and a WEB_PATH_ESCAPE_SET
# file). Reasons never reach the matcher; an undocumented row is a review miss,
# not a silent one.
strip_set_comments() {
  grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

declared_globs() {
  if [ -n "${WEB_PATH_ESCAPE_SET:-}" ]; then
    if [ ! -r "$WEB_PATH_ESCAPE_SET" ]; then
      echo "web-path-escape-check: REFUSING TO MEASURE — WEB_PATH_ESCAPE_SET=$WEB_PATH_ESCAPE_SET is not readable." >&2
      exit 2
    fi
    strip_set_comments < "$WEB_PATH_ESCAPE_SET"
    return 0
  fi
  strip_set_comments <<'SET'
# the gate's subject
web/**
# lighthouse job config, read by the `lighthouse` job in ci.yml
lighthouserc.json
# the workflow that resolves this set
.github/workflows/ci.yml
# this file: the set and its ratchet are one declaration
scripts/web-path-escape-check.sh

# ---- census arm 1: web/package.json `file:` dependencies --------------------
# built by web-checks' "Build @barkpark/core (web's linked dependency)" and
# "Build @barkpark/react (web's linked dependency)" steps before web/ installs.
js/packages/core/**
js/packages/react/**
# ---- census arm 2: `../`-escaping literal in web/package.json scripts -------
# web/package.json "test": "node ../scripts/node-test-floor.mjs ..." — the
# harness web-checks' "Unit tests" step (`pnpm run test`) actually executes.
scripts/node-test-floor.mjs
# ---- census arm 3: `../`-escaping literals in web/ source -------------------
# pinned by web/__tests__/template-format-date.test.ts and
# template-webhook-lazy.test.ts.
js/packages/create-barkpark-app/templates/**

# ---- the js/ workspace ROOT files the web-checks job reads ------------------
# NOT surfaced by the census: the census resolves literals written INSIDE web/,
# and nothing in web/ names these by path. They are read because two web-checks
# steps run `pnpm` with `working-directory: js`:
#
#     - name: Build @barkpark/core (web's linked dependency)
#       working-directory: js
#       run: |
#         pnpm install --frozen-lockfile
#         pnpm --filter @barkpark/core build
#
# so a change to any of them changes what those steps install or emit, and the
# dist/ that web/'s Typecheck and Unit tests then consume. Without these rows a
# lockfile bump dispatches NO web job and `Web gate` greens having run nothing.
#
# the exact file `pnpm install --frozen-lockfile` (working-directory: js) pins;
# also web-checks' Setup Node `cache-dependency-path:` first entry.
js/pnpm-lock.yaml
# the workspace root manifest that same install resolves: the toolchain pins
# (turbo, typescript, tsup) and the `pnpm.overrides` block that rewrites
# transitive versions inside the dist web/ typechecks against.
js/package.json
# declares `packages/*`, which is what makes `pnpm --filter @barkpark/core` and
# `--filter @barkpark/react` resolve to a package at all. Break it and both
# build steps fail — or worse, filter to nothing and succeed.
js/pnpm-workspace.yaml
# js/packages/core/tsconfig.json and js/packages/react/tsconfig.json both
# `"extends": "../../tsconfig.base.json"`, so it governs the .d.ts those two
# build steps emit — the types web-checks' "Typecheck" step checks against.
js/tsconfig.base.json
# CONSERVATIVE, and NOT read by any web-checks step today: `pnpm --filter
# @barkpark/core build` runs the package's own script (`tsup && node
# ../../scripts/post-build-dts.mjs`), never `turbo run build`. Declared so that
# routing those builds back through turbo (`pnpm build` at js/ root, which IS
# `turbo run build`) cannot silently un-dispatch the gate.
# RETIRE THIS ROW if ci.yml's web-checks still calls `pnpm --filter` directly
# and you are content that turbo's task graph cannot reach web/'s inputs.
js/turbo.json

# ---- the MAX_HITS lock's own scan roots (task-19107773e2c41c5d) -------------
# web/__tests__/max-hits-lock.test.ts DERIVES the MAX_HITS declaration set by
# WALKING web/, templates/ and js/ — it refuses to trust a path list, because
# the row that first noticed the mirrored constant counted two sites when there
# were six. The census below cannot surface those two reads: the test composes
# its roots from `new URL("../../", import.meta.url)` + path.join, not from a
# `../`-escaping string literal, and EXISTENCE-of-literal is what arm 3 keys on.
# So they are declared by hand. Without these rows a seventh `const MAX_HITS`
# landing in templates/ or js/ dispatches NO web job at all and the lock is
# blind on the exact PR it exists to red — the vacuous green this whole file
# was written to refuse.
# RETIRE THESE ROWS only together with that test.
templates/**
js/**
SET
}

# The census floor — a LOWER BOUND ON THE SCANNER, never a headcount of the
# repo. A regex that stopped matching would report "0 uncovered reads" and exit
# 0: clean-looking and completely blind, which is the failure mode this whole
# file exists to refuse. Measured population on this tree 2026-09-11: 5
# distinct resolved cross-tree reads (`--list-reads`) — two `file:` packages,
# the node --test floor and two starter-template files. The floor is 3, so
# deleting a fixture is not a false red while losing a whole ARM is caught:
# arm 1 alone contributes 2 rows, arm 3 contributes 2. Adding a read does not
# raise it.
WEB_ESCAPE_MIN=3

# GitHub path globs -> one anchored alternation ERE. `**/` spans separators,
# `*` does not. Lifted character-for-character from go-path-escape-check.sh's
# g2e() so the two cannot disagree about what a glob means.
globs_to_ere() {
  awk '
    function g2e(p,   rx, i, c, n) {
      rx = ""; i = 1; n = length(p)
      while (i <= n) {
        c = substr(p, i, 1)
        if (c == "*") {
          if (substr(p, i, 3) == "**/") { rx = rx "(.*/)?"; i = i + 3; continue }
          if (substr(p, i, 2) == "**")  { rx = rx ".*";     i = i + 2; continue }
          rx = rx "[^/]*"; i = i + 1; continue
        }
        if (c == "?") { rx = rx "[^/]" }
        else if (index(".+()[]{}^$|\\", c) > 0) { rx = rx "\\" c }
        else { rx = rx c }
        i = i + 1
      }
      return "^" rx "$"
    }
    NF { if (out != "") out = out "|"; out = out g2e($0) }
    END { print out }
  '
}

# ---------------------------------------------------------------------------
# THE CENSUS — resolved cross-tree reads, one `<path><TAB><source>` per line
# ---------------------------------------------------------------------------
list_reads() {
  local root="${1:-$REPO_ROOT}"
  if [ ! -d "$root/web" ]; then
    echo "web-path-escape-check: REFUSING TO MEASURE — $root/web is not a directory, so no read census exists." >&2
    return 2
  fi
  ( cd -- "$root" && python3 - <<'PY'
import json, os, re, sys

rows = []


def resolve(base_dir, literal):
    """Resolve a relative literal against the reading file's directory."""
    p = os.path.normpath(os.path.join(base_dir, literal))
    if p.startswith(".."):          # escapes the repo entirely
        return None
    return p


def record(path, source):
    if path is None or not os.path.exists(path):
        return                      # EXISTENCE IS THE FILTER
    if path in (".", ""):
        # THE REPO ROOT ITSELF, named rather than left to be rediscovered:
        # web/__tests__/consumer-csp-parity.test.ts joins `"../.."` and then
        # appends segments computed at run time. Resolving that needs an
        # expression evaluator, not a scanner, and the honest declaration for
        # it would be `**` — every path in the repo, which is the wholesale
        # dispatch a path set exists to avoid. A KNOWN hole with a named shape.
        return
    parts = path.split("/")
    if parts[0] in ("web", ".git") or "node_modules" in parts:
        return
    rows.append((path, source))


pkg_path = "web/package.json"
if os.path.exists(pkg_path):
    pkg = json.load(open(pkg_path))
    # ARM 1 — `file:` dependencies.
    for section in ("dependencies", "devDependencies"):
        for name, spec in (pkg.get(section) or {}).items():
            if isinstance(spec, str) and spec.startswith("file:"):
                record(resolve("web", spec[len("file:"):]), pkg_path + " (" + name + ")")
    # ARM 2 — `../`-escaping literals in the scripts.
    for name, body in (pkg.get("scripts") or {}).items():
        if not isinstance(body, str):
            continue
        for m in re.finditer(r"(?:^|[\s'\"=])((?:\.\./)+[A-Za-z0-9_./-]+)", body):
            record(resolve("web", m.group(1)), pkg_path + " (scripts." + name + ")")

# ARM 3 — `../`-escaping string literals in web/ source.
for dirpath, dirnames, filenames in os.walk("web"):
    dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".next", ".git")]
    for fn in filenames:
        if not fn.endswith((".ts", ".tsx", ".js", ".mjs", ".cjs")):
            continue
        src = os.path.join(dirpath, fn)
        try:
            text = open(src, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in re.finditer(r"""['"]((?:\.\./)+[A-Za-z0-9_./@-]+)['"]""", text):
            record(resolve(dirpath, m.group(1)), src)

seen = set()
for path, source in rows:
    if path in seen:
        continue
    seen.add(path)
    print("%s\t%s" % (path, source))
PY
  )
}

# ---------------------------------------------------------------------------
# --match — the dispatcher's question
# ---------------------------------------------------------------------------
# Changed paths on STDIN, one per line. Prints `true` or `false` and nothing
# else. An unknown set name is exit 2 with a named refusal, never a verdict:
# ci.yml's dispatcher turns a refusal into `web=true` (run everything) out loud,
# so a version skew between this file and the workflow costs a runner, never a
# silent skip.
match_set() {
  local want="$1" ere
  if [ "$want" != "web" ]; then
    echo "web-path-escape-check: unknown path set '$want' (want web)" >&2
    exit 2
  fi
  ere="$(declared_globs | globs_to_ere)"
  if [ -z "$ere" ]; then
    echo "web-path-escape-check: REFUSING TO MEASURE — the declared set compiled to an EMPTY regex; every path would read as not-matching and the gate would skip." >&2
    exit 2
  fi
  # `grep -E` over a here-string, never a pipe: `grep -q` exits the instant it
  # matches and a writer still holding bytes takes SIGPIPE, which `pipefail`
  # promotes over the match that DID occur (the house D37 rule).
  local changed
  changed="$(cat)"
  if grep -Eq -- "$ere" <<<"$changed"; then printf 'true'; else printf 'false'; fi
  echo
}

# ---------------------------------------------------------------------------
# the ratchet
# ---------------------------------------------------------------------------
ratchet() {
  local root="${1:-$REPO_ROOT}" census ere n uncovered=0 path source
  census="$(list_reads "$root")" || return 2
  ere="$(declared_globs | globs_to_ere)"
  if [ -z "$ere" ]; then
    echo "web-path-escape-check: REFUSING TO MEASURE — the declared set compiled to an EMPTY regex." >&2
    return 2
  fi

  n="$(printf '%s\n' "$census" | grep -c '.' )"
  if [ "$n" -lt "$WEB_ESCAPE_MIN" ]; then
    echo "web-path-escape-check: REFUSING TO MEASURE — the census resolved ${n} cross-tree reads, under the floor of ${WEB_ESCAPE_MIN}." >&2
    echo "  A census this small means the SCANNER stopped matching, not that web/ got simpler. Re-read the three arms in this file's header." >&2
    return 2
  fi

  echo "web-path-escape-check: ${n} resolved cross-tree reads, declared set:"
  declared_globs | sed 's/^/  - /'
  echo

  while IFS="$(printf '\t')" read -r path source; do
    [ -n "$path" ] || continue
    # A directory read (`js/packages/core`) is covered by a glob over its
    # contents: probe both spellings, or `js/packages/core/**` would read as
    # not covering the very dependency it was written for.
    if grep -Eq -- "$ere" <<<"$path" || grep -Eq -- "$ere" <<<"$path/__probe__"; then
      echo "  ok        ${path}    <- ${source}"
    else
      echo "  ESCAPED   ${path}    <- ${source}"
      uncovered=$((uncovered + 1))
    fi
  done <<<"$census"

  echo
  if [ "$uncovered" -ne 0 ]; then
    echo "::error::web-path-escape-check: ${uncovered} read(s) of the web/ gate are NOT in its declared path set. A PR touching one of them dispatches NO web job, and 'Web gate' then reports green over a suite that never ran. Declare them in declared_globs() in this file (ci.yml resolves its job-level if: through it)." >&2
    return 1
  fi
  echo "web-path-escape-check: every resolved read is dispatched on."
  return 0
}

# ---------------------------------------------------------------------------
# --selftest — the ratchet must be able to LOSE
# ---------------------------------------------------------------------------
selftest() {
  local pass=0 fail=0 tmp out rc
  ok() { pass=$((pass + 1)); echo "  ok   — $1"; }
  no() { fail=$((fail + 1)); echo "  FAIL — $1" >&2; }

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/web-path-escape.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  echo "web-path-escape-check --selftest"
  echo

  # ── case 1: --match over the REAL declared set ──────────────────────────
  echo "case 1: --match web answers over the real declared set"
  out="$(printf '%s\n' "web/app/page.tsx" | "$0" --match web)"
  [ "$out" = "true" ] && ok "web/app/page.tsx -> true" || no "web/app/page.tsx -> '$out'"
  out="$(printf '%s\n' "docs/INDEX.md" | "$0" --match web)"
  [ "$out" = "false" ] && ok "docs/INDEX.md -> false" || no "docs/INDEX.md -> '$out'"
  # THE THREE READS THE OLD TRIGGER MISSED. Each is a measured hole, not a
  # hypothetical: before this slice all three answered `false` and the web
  # suite that pins them never ran.
  for p in \
    "js/packages/core/src/index.ts" \
    "scripts/node-test-floor.mjs" \
    "js/packages/create-barkpark-app/templates/_shared/lib/format-date.ts"; do
    out="$(printf '%s\n' "$p" | "$0" --match web)"
    [ "$out" = "true" ] && ok "$p -> true (a read the old ci.yml trigger missed)" ||
      no "$p -> '$out', wanted true"
  done
  out="$(printf '%s\n' "api/lib/barkpark.ex" | "$0" --match web)"
  [ "$out" = "false" ] && ok "api/lib/barkpark.ex -> false" || no "api/lib/barkpark.ex -> '$out'"
  # An unknown set is a REFUSAL, never a verdict.
  out="$(printf '%s\n' "web/x" | "$0" --match census 2>/dev/null)" ; rc=$?
  [ "$rc" = "2" ] && ok "--match census (unknown set) exits 2, prints no verdict" ||
    no "--match census exited $rc, wanted 2"
  echo

  # ── case 2: the ratchet on the REAL tree is green ───────────────────────
  echo "case 2: the ratchet is green on this tree"
  out="$(ratchet "$REPO_ROOT" 2>&1)"; rc=$?
  [ "$rc" = "0" ] && ok "ratchet exit 0 on $REPO_ROOT" || { no "ratchet exit $rc on the real tree"; printf '%s\n' "$out" | sed 's/^/        /' >&2; }
  echo

  # ── case 3: the MUTANT — a new undeclared read must RED ─────────────────
  # A fixture tree, because mutating the real one is not available to a check
  # that must also run on a read-only checkout. The mutation is the exact shape
  # the ratchet exists to catch: web/ grows a read of a tree nobody declared.
  echo "case 3: an undeclared cross-tree read reds the ratchet (and declaring it greens it)"
  mkdir -p "$tmp/tree/web/__tests__" "$tmp/tree/js/packages/core" "$tmp/tree/js/packages/react" \
           "$tmp/tree/js/packages/create-barkpark-app/templates/_shared/lib" "$tmp/tree/scripts" "$tmp/tree/newtree"
  cat >"$tmp/tree/web/package.json" <<'JSON'
{
  "scripts": { "test": "node ../scripts/node-test-floor.mjs -- '__tests__/*.test.ts'" },
  "dependencies": {
    "@barkpark/core": "file:../js/packages/core",
    "@barkpark/react": "file:../js/packages/react"
  }
}
JSON
  echo "x" >"$tmp/tree/scripts/node-test-floor.mjs"
  echo "x" >"$tmp/tree/js/packages/core/package.json"
  echo "x" >"$tmp/tree/js/packages/react/package.json"
  echo "x" >"$tmp/tree/js/packages/create-barkpark-app/templates/_shared/lib/format-date.ts"
  echo 'const a = "../../js/packages/create-barkpark-app/templates/_shared/lib/format-date.ts";' \
    >"$tmp/tree/web/__tests__/a.test.ts"

  # THE CONTROL FIRST: the same fixture, unmutated, must be GREEN — otherwise
  # the red below proves nothing about the mutation.
  out="$(WEB_PATH_ESCAPE_ROOT="$tmp/tree" ratchet "$tmp/tree" 2>&1)"; rc=$?
  [ "$rc" = "0" ] && ok "control: the unmutated fixture tree is green" ||
    { no "control: the unmutated fixture tree exited $rc — the mutation below proves nothing"; printf '%s\n' "$out" | sed 's/^/        /' >&2; }

  # THE MUTATION: a test grows a read of newtree/, which no glob declares.
  echo "x" >"$tmp/tree/newtree/thing.ts"
  echo 'const b = "../../newtree/thing.ts";' >>"$tmp/tree/web/__tests__/a.test.ts"
  out="$(WEB_PATH_ESCAPE_ROOT="$tmp/tree" ratchet "$tmp/tree" 2>&1)"; rc=$?
  if [ "$rc" = "1" ] && grep -q 'ESCAPED   newtree/thing.ts' <<<"$out"; then
    ok "mutant: the undeclared read reds the ratchet BY NAME (exit 1, 'ESCAPED newtree/thing.ts')"
  else
    no "mutant: exit $rc and the ESCAPED line for newtree/thing.ts was not printed"
    printf '%s\n' "$out" | sed 's/^/        /' >&2
  fi

  # THE RESTORE: declaring it greens the same tree. Without this arm the red
  # above could be a ratchet that reds on everything.
  printf 'web/**\nscripts/node-test-floor.mjs\njs/packages/core/**\njs/packages/react/**\njs/packages/create-barkpark-app/templates/**\nnewtree/**\n' >"$tmp/set.txt"
  out="$(WEB_PATH_ESCAPE_SET="$tmp/set.txt" WEB_PATH_ESCAPE_ROOT="$tmp/tree" ratchet "$tmp/tree" 2>&1)"; rc=$?
  [ "$rc" = "0" ] && ok "restore: declaring newtree/** greens the same tree" ||
    { no "restore: exit $rc"; printf '%s\n' "$out" | sed 's/^/        /' >&2; }
  echo

  # ── case 4: a blind scanner REFUSES, it does not report clean ───────────
  echo "case 4: a census under the floor refuses to measure (exit 2), never exits 0"
  mkdir -p "$tmp/bare/web"
  echo '{}' >"$tmp/bare/web/package.json"
  out="$(WEB_PATH_ESCAPE_ROOT="$tmp/bare" ratchet "$tmp/bare" 2>&1)"; rc=$?
  if [ "$rc" = "2" ] && grep -q 'REFUSING TO MEASURE' <<<"$out"; then
    ok "an empty census exits 2 with REFUSING TO MEASURE, not a serene 0"
  else
    no "an empty census exited $rc: $out"
  fi
  # …and a tree with no web/ at all is the same refusal, never a verdict.
  mkdir -p "$tmp/noweb"
  out="$(WEB_PATH_ESCAPE_ROOT="$tmp/noweb" ratchet "$tmp/noweb" 2>&1)"; rc=$?
  [ "$rc" = "2" ] && ok "a tree with no web/ exits 2" || no "a tree with no web/ exited $rc"
  echo

  echo "----"
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
case "${1:---ratchet}" in
  --ratchet)
    ratchet "$REPO_ROOT"
    exit $?
    ;;
  --list-reads)
    list_reads "$REPO_ROOT"
    exit $?
    ;;
  --print-set)
    declared_globs
    exit 0
    ;;
  --match)
    match_set "${2:-}"
    exit 0
    ;;
  --selftest)
    selftest
    exit $?
    ;;
  -h | --help)
    sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "web-path-escape-check: unknown argument '$1'" >&2
    echo "usage: $0 [--ratchet|--list-reads|--print-set|--match web|--selftest]" >&2
    exit 2
    ;;
esac
