#!/usr/bin/env bash
# pre-commit-hook.test.sh — drive .githooks/pre-commit through REAL `git commit`
# calls in a throwaway repo, and prove each of its blocking checks can refuse.
#
# The hook is copied VERBATIM with the ratchet script and the real baseline
# into a temp repo whose api/ is a stub mix project (no deps, so `mix format`
# runs without the real app's import_deps). Nothing is committed anywhere else.
#
# Arms (task-eb42388a71b8d277):
#   A  a staged api/test file with a NEW unreachable assert message is REFUSED,
#      the output quotes the script's own RED line, and HEAD does not move.
#      Control inside the arm: the file is formatted, so the refusal is the
#      ratchet's, not mix format's.
#   B  the same file with the site fixed (bind, then assert) COMMITS.
#   C  a .md-only commit runs NEITHER check (no "mix format", no "ratchet"
#      line) and commits. Timed beside A.
#   D  a .go-only commit: same as C.
#   E  an unformatted AND defective file: BOTH refusals print — the first
#      blocking check failing does not hide the second.
#   F  an api/lib file (not api/test) with the same site: the ratchet does NOT
#      run on it (scope is api/test; CI's corpus is api/test).
#
# Needs git, elixir and mix on PATH. Usage: bash scripts/pre-commit-hook.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for bin in git elixir mix perl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "pre-commit-hook.test: $bin not on PATH — REFUSING" >&2; exit 3; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"
mkdir -p "$R/.githooks" "$R/scripts" "$R/.github" "$R/api/test" "$R/api/lib" "$R/docs" "$R/cmd"
cp "$ROOT/.githooks/pre-commit" "$R/.githooks/pre-commit"
cp "$ROOT/scripts/unreachable-assert-message-check.sh" "$R/scripts/"
cp "$ROOT/.github/unreachable-assert-message.allow" "$R/.github/"
chmod +x "$R/.githooks/pre-commit"
cat > "$R/api/mix.exs" <<'EX'
defmodule HookProbe.MixProject do
  use Mix.Project
  def project, do: [app: :hook_probe, version: "0.1.0", deps: []]
end
EX
printf '[inputs: ["{mix,.formatter}.exs", "{lib,test}/**/*.{ex,exs}"]]\n' > "$R/api/.formatter.exs"
echo "# probe" > "$R/docs/README.md"

g() { git -C "$R" "$@"; }
g init -q
g config user.email hook-probe@example.invalid
g config user.name hook-probe
g config commit.gpgsign false
g add -A
g commit -q -m init            # hooksPath not yet set: the seed commit is not under test
g config core.hooksPath .githooks

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
fails=0
arm() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fails=$((fails+1)); return 0; }
commit() { # $1 message; sets out, rc, ms
  local t0; t0="$(now_ms)"
  rc=0; out="$(g commit -m "$1" 2>&1)" || rc=$?
  ms=$(( $(now_ms) - t0 ))
}

DEFECT='defmodule HookProbeTest do
  use ExUnit.Case

  test "probe" do
    assert {:ok, _x} = f(), "msg"
  end

  defp f, do: {:ok, 1}
end
'
FIXED='defmodule HookProbeTest do
  use ExUnit.Case

  test "probe" do
    result = f()
    assert match?({:ok, _}, result), "msg"
  end

  defp f, do: {:ok, 1}
end
'
P=api/test/hook_probe_test.exs

echo "pre-commit-hook.test"
echo

# A ---------------------------------------------------------------------------
printf '%s' "$DEFECT" > "$R/$P"; g add "$P"
head0="$(g rev-parse HEAD)"
commit "A"; ms_a=$ms
red_line="RED  $P — 1 unreachable assert message(s), baseline 0"
if [ "$rc" != 0 ] && grep -qF "$red_line" <<<"$out" && [ "$(g rev-parse HEAD)" = "$head0" ] \
   && ! grep -q "unformatted Elixir files staged" <<<"$out"; then
  arm "ok" "(A) staged defective test REFUSED (rc $rc, ${ms_a} ms), quoting: $red_line"
else
  arm "FAIL" "(A) defective test not refused by the ratchet (rc $rc) — output: $(tr '\n' '|' <<<"$out")"
fi

# B ---------------------------------------------------------------------------
printf '%s' "$FIXED" > "$R/$P"; g add "$P"
commit "B"; ms_b=$ms
if [ "$rc" = 0 ] && grep -q "unreachable-assert-message ratchet on 1 staged api/test file" <<<"$out" \
   && grep -q "OK — 0 site(s) at or below baseline" <<<"$out"; then
  arm "ok" "(B) same file, site fixed, COMMITS after both checks ran (${ms_b} ms)"
else
  arm "FAIL" "(B) fixed file did not commit cleanly (rc $rc) — output: $(tr '\n' '|' <<<"$out")"
fi

# C ---------------------------------------------------------------------------
echo "more" >> "$R/docs/README.md"; g add docs/README.md
commit "C"; ms_c=$ms
if [ "$rc" = 0 ] && ! grep -q "mix format" <<<"$out" && ! grep -q "ratchet" <<<"$out"; then
  arm "ok" "(C) .md-only commit ran NEITHER check (${ms_c} ms)"
else
  arm "FAIL" "(C) .md-only commit ran a check or failed (rc $rc) — output: $(tr '\n' '|' <<<"$out")"
fi

# D ---------------------------------------------------------------------------
printf 'package main\n\nfunc main() {}\n' > "$R/cmd/main.go"; g add cmd/main.go
commit "D"; ms_d=$ms
if [ "$rc" = 0 ] && ! grep -q "mix format" <<<"$out" && ! grep -q "ratchet" <<<"$out"; then
  arm "ok" "(D) .go-only commit ran NEITHER check (${ms_d} ms)"
else
  arm "FAIL" "(D) .go-only commit ran a check or failed (rc $rc) — output: $(tr '\n' '|' <<<"$out")"
fi

# E ---------------------------------------------------------------------------
P2=api/test/hook_probe_two_test.exs
printf '%s' "$DEFECT" | sed 's/HookProbeTest/HookProbeTwoTest/; s/assert {:ok, _x} = f(), "msg"/assert   {:ok, _x} =   f(), "msg"/' > "$R/$P2"
g add "$P2"
head0="$(g rev-parse HEAD)"
commit "E"
if [ "$rc" != 0 ] && grep -q "unformatted Elixir files staged" <<<"$out" \
   && grep -qF "RED  $P2 — 1 unreachable assert message(s), baseline 0" <<<"$out" \
   && [ "$(g rev-parse HEAD)" = "$head0" ]; then
  arm "ok" "(E) unformatted + defective: BOTH refusals print, HEAD unmoved"
else
  arm "FAIL" "(E) expected both refusals (rc $rc) — output: $(tr '\n' '|' <<<"$out")"
fi
g rm -q --cached "$P2"; rm -f "$R/$P2"

# F ---------------------------------------------------------------------------
P3=api/lib/hook_probe_lib.ex
printf '%s' "$DEFECT" | sed 's/HookProbeTest/HookProbeLib/; s/use ExUnit.Case//' > "$R/$P3"
( cd "$R/api" && mix format lib/hook_probe_lib.ex )
g add "$P3"
commit "F"
if [ "$rc" = 0 ] && grep -q "mix format --check-formatted on 1 file" <<<"$out" && ! grep -q "ratchet" <<<"$out"; then
  arm "ok" "(F) an api/lib file runs the format check but NOT the ratchet"
else
  arm "FAIL" "(F) api/lib scope wrong (rc $rc) — output: $(tr '\n' '|' <<<"$out")"
fi

echo
echo "timings: test-file commit refused ${ms_a} ms, test-file commit passed ${ms_b} ms, .md-only ${ms_c} ms, .go-only ${ms_d} ms"
if [ "$fails" -gt 0 ]; then
  echo "SELFTEST FAILED: $fails of 6 arms failed"
  exit 1
fi
echo "SELFTEST PASSED: 6 of 6 arms"
