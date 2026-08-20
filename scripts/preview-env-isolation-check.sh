#!/usr/bin/env bash
# preview-env-isolation-check.sh — the preview-route pollution tripwire.
#
# `Application.put_env(:barkpark, :preview, …)` mutates a PROCESS-GLOBAL key.
# ExUnit runs `async: true` cases CONCURRENTLY in the same BEAM process, so a
# test that flips the preview config while another async case reads it leaks
# state across the suite — a flaky, order-dependent "preview/post-pollution"
# red with no seed. The three preview-mutating test files today are correctly
# isolated (`async: false` + an `on_exit` restore + supervisor drain), so this
# gate does NOT re-assert what already holds — it DEFENDS that surface against
# a FUTURE file that reaches for the same global key without the isolation:
#
#   INVARIANT — every api/test/**/*.exs that makes a real
#   `Application.put_env(:barkpark, :preview, …)` call MUST declare an EXPLICIT
#   `async: false` (never rely on the ExUnit default, never `async: true`) AND
#   contain an `on_exit` restore. A file missing either REDS (exit 1), naming
#   file:line once per missing reason.
#
# Unlike scripts/tenant-scope-check.sh there is NO baseline file — a preview-env
# mutation without isolation is always a real bug, never a grandfathered
# occurrence. A `put_env` living only in `@moduledoc`/`@doc` prose or a comment
# is NOT a real call and is never flagged.
#
# NOT to be confused with scripts/preview-parity-check.sh — that guards the
# preview CONTRACT (field-parity + oEmbed ban), a different concern.
#
# Modeled on scripts/tenant-scope-check.sh (Python scanner + heredoc/comment
# stripping + a --selftest tripwire that plants its fixture in a TEMP dir).
# bash 3.2 compatible.
#
# Usage:
#   scripts/preview-env-isolation-check.sh              # check (CI + merge gate)
#   scripts/preview-env-isolation-check.sh --selftest   # tripwire: prove the gate
#                                                       # REDs on a planted un-isolated
#                                                       # put_env (temp dir; plants
#                                                       # nothing in the tree)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# TESTDIR is overridable (the --selftest tripwire points it at a temp tree so it
# can prove the scanner reds without planting in the real source).
TESTDIR="${PREVIEW_ISO_TESTDIR:-$ROOT/api/test}"

# --- self-test tripwire ------------------------------------------------------
# Mirrors scripts/tenant-scope-check.sh --selftest: stand up a synthetic api/test
# in a temp dir and prove (0) a correctly-isolated file PASSES, (a) an
# `async: true` file REDs (missing explicit async:false), (b) an `async: false`
# file with NO on_exit REDs, (c) `async: false` + on_exit PASSES, and (d) a
# put_env living only in @moduledoc prose is NOT flagged. Guards the gate against
# a future edit that silently weakens the scanner.
if [ "${1:-}" = "--selftest" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/test/barkpark_web/integration"
  export PREVIEW_ISO_TESTDIR="$TMP/test"

  fail_selftest() { echo "preview-env-isolation-check --selftest: FAILED — $*"; exit 1; }

  # (0) a correctly-isolated file → must PASS
  cat > "$TMP/test/barkpark_web/integration/clean_test.exs" <<'EX'
defmodule Demo.CleanTest do
  use BarkparkWeb.ConnCase, async: false

  setup do
    prior = Application.get_env(:barkpark, :preview)
    Application.put_env(:barkpark, :preview, secret: "s", ttl_seconds: 600)
    on_exit(fn -> Application.put_env(:barkpark, :preview, prior || []) end)
    :ok
  end
end
EX
  "$0" >/dev/null 2>&1 || fail_selftest "a correctly-isolated (async:false + on_exit) file did NOT pass"

  # (a) an `async: true` file → must RED (no explicit async:false)
  cat > "$TMP/test/barkpark_web/integration/async_true_test.exs" <<'EX'
defmodule Demo.AsyncTrueTest do
  use BarkparkWeb.ConnCase, async: true

  setup do
    Application.put_env(:barkpark, :preview, secret: "s")
    on_exit(fn -> Application.put_env(:barkpark, :preview, []) end)
    :ok
  end
end
EX
  if "$0" >/dev/null 2>&1; then
    fail_selftest "an async:true preview-env mutation did NOT red the gate"
  fi
  rm -f "$TMP/test/barkpark_web/integration/async_true_test.exs"

  # (b) `async: false` but NO on_exit → must RED (missing restore)
  cat > "$TMP/test/barkpark_web/integration/no_onexit_test.exs" <<'EX'
defmodule Demo.NoOnExitTest do
  use BarkparkWeb.ConnCase, async: false

  setup do
    Application.put_env(:barkpark, :preview, secret: "s")
    :ok
  end
end
EX
  if "$0" >/dev/null 2>&1; then
    fail_selftest "an async:false preview-env mutation with NO on_exit did NOT red the gate"
  fi

  # (c) add the on_exit restore → must PASS
  cat > "$TMP/test/barkpark_web/integration/no_onexit_test.exs" <<'EX'
defmodule Demo.NoOnExitTest do
  use BarkparkWeb.ConnCase, async: false

  setup do
    Application.put_env(:barkpark, :preview, secret: "s")
    on_exit(fn -> Application.put_env(:barkpark, :preview, []) end)
    :ok
  end
end
EX
  "$0" >/dev/null 2>&1 || fail_selftest "an isolated (async:false + on_exit) file did NOT pass after the fix"

  # (d) a put_env living ONLY in @moduledoc prose → must NOT be flagged (async:true, no on_exit)
  cat > "$TMP/test/barkpark_web/integration/prose_only_test.exs" <<'EX'
defmodule Demo.ProseOnlyTest do
  @moduledoc """
  This file talks about Application.put_env(:barkpark, :preview, …) in prose
  but never actually calls it, so it needs no async:false or on_exit.
  """
  use BarkparkWeb.ConnCase, async: true
end
EX
  "$0" >/dev/null 2>&1 || fail_selftest "a put_env mentioned ONLY in @moduledoc prose was flagged as a real call"

  echo "preview-env-isolation-check --selftest: PASS — gate reds on async:true + missing on_exit, passes when isolated, ignores prose-only mentions."
  exit 0
fi

python3 - "$TESTDIR" <<'PY'
import os, re, sys

testdir = sys.argv[1]

# A REAL preview-env mutation: Application.put_env( … :barkpark … :preview … ).
# The two atoms are the first two args; the `secret:`/value list may spill onto
# the next line, but `put_env(:barkpark, :preview` is one line in every real
# call. Matched on a comment/heredoc-stripped copy so prose never counts.
PUT_ENV = re.compile(
    r"\bApplication\.put_env\(\s*:barkpark\s*,\s*:preview\b")

# Explicit non-async declaration (never the ExUnit default, never async: true).
ASYNC_FALSE = re.compile(r"\basync:\s*false\b")
# The teardown restore.
ON_EXIT = re.compile(r"\bon_exit\b")

# Length-preserving blank (keeps line numbers + line indices aligned).
def blank(m):
    return re.sub(r"[^\n]", " ", m.group(0))

# Strip @doc/@moduledoc heredocs (prose mentions of the call live there) and
# full-line `#` comments. We do NOT cut at an inline `#` — Elixir `#{}`
# interpolation makes that unsafe — so a real call sharing a line with a trailing
# comment is still detected.
DOC_HEREDOC = re.compile(r'@(?:module)?doc\s+(?:~[A-Za-z])?"""(?:.*?)"""', re.S)

def scan(path):
    raw = open(path, encoding="utf-8").read()
    s = DOC_HEREDOC.sub(blank, raw)
    stripped_lines = s.split("\n")
    code_lines = []          # code lines excluding full-line comments
    put_env_lines = []       # line numbers of real put_env calls
    for i, sline in enumerate(stripped_lines, 1):
        if re.match(r"^\s*#", sline):
            continue
        code_lines.append(sline)
        if PUT_ENV.search(sline):
            put_env_lines.append(i)
    code = "\n".join(code_lines)
    return put_env_lines, code

# Walk api/test/**/*.exs.
violations = []   # (rel, lineno, reason)
mutating = []     # rel paths that make a real, ISOLATED call (for the PASS report)
for dirpath, _dirs, files in os.walk(testdir):
    for fn in sorted(files):
        if not fn.endswith(".exs"):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, testdir)
        put_env_lines, code = scan(path)
        if not put_env_lines:
            continue
        line = put_env_lines[0]
        missing = []
        if not ASYNC_FALSE.search(code):
            missing.append("no explicit `async: false` (the file mutates the "
                           "process-global :preview key — never rely on the "
                           "ExUnit default, never async: true)")
        if not ON_EXIT.search(code):
            missing.append("no `on_exit` restore of the prior :preview config")
        if missing:
            for reason in missing:
                violations.append((rel, line, reason))
        else:
            mutating.append(rel)

if violations:
    print("preview-env-isolation-check: FAILED — preview-env mutation(s) without "
          "the required test isolation.\n")
    for rel, line, reason in sorted(violations):
        print("  %s:%s  %s" % (rel, line, reason))
    print("\n  A test that calls Application.put_env(:barkpark, :preview, …) writes "
          "a PROCESS-GLOBAL\n  key that concurrent async cases read — it MUST declare "
          "an explicit `async: false`\n  (e.g. `use BarkparkWeb.ConnCase, async: false`) "
          "AND restore the prior value in an\n  `on_exit` callback, mirroring "
          "test/barkpark_web/integration/preview_routes_test.exs.")
    sys.exit(1)

print("preview-env-isolation-check: PASS — %d preview-env-mutating test file(s), "
      "all async:false + on_exit." % len(mutating))
for rel in sorted(mutating):
    print("  %s" % rel)
sys.exit(0)
PY
