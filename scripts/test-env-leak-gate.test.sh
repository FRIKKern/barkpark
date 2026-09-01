#!/usr/bin/env bash
#
# test-env-leak-gate.test.sh — the harness for scripts/test-env-leak-gate.sh.
#
# A gate nobody can prove FAILS is not a gate. The cases that matter here are
# the ones that make the instrument red on purpose:
#
#   * an unrestored `Application.put_env` must red, naming file AND line   (2)
#   * the SAME fixture with an `on_exit` restore must green                (3)
#   * an allowlist row with no reason must red                            (5,6)
#   * a population of ZERO scanned files must red, never print OK        (8,9)
#   * a file the parser cannot read must red BY NAME                      (10)
#   * a GUTTED copy of the gate must FAIL this suite                     (12)
#
# Case 12 is the one that stops the other eleven passing vacuously. A detector
# can be deleted and every green case stays green — the suite only measures
# something if a gate with its detection removed comes back RED here.
#
# Everything runs against synthetic trees in a temp dir. Nothing is planted in
# api/test, which other lanes own.
#
# Executed by .github/workflows/elixir.yml's `mix-test` job, as a STEP beside
# the `unreachable-assert-message-check.sh` and `client-ip-resolver-check.sh`
# ratchets it is modelled on — NOT as a job. Those two record why: adding a
# blocking job forces a six-place change (job · needs · decide binding · the
# `env -i` simulators · the spec-authority marker · the merge-authority claim
# count), and each of those has its own correct ratchet that would red.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/test-env-leak-gate.sh"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "  ok   — $1"
}
no() {
  fail=$((fail + 1))
  echo "  FAIL — $1" >&2
}

# ── never read the status of a pipeline whose writer can still be writing ────
# `A | grep -q …` exits the instant grep matches; A then takes SIGPIPE (141) on
# its next write and `set -o pipefail` promotes that over grep's success, so a
# match reads as a MISS — intermittently, under load, exactly where a gate is
# least observed. Every check below therefore runs the gate into a FILE, reads
# the real exit code into a variable, and greps the FILE.
run_gate() {
  # run_gate <outfile> <scandir> <allowlist> [args…] ; echoes the exit code
  local out="$1" scandir="$2" allow="$3"
  shift 3
  local rc=0
  TEST_ENV_LEAK_SCANDIR="$scandir" TEST_ENV_LEAK_ALLOWLIST="$allow" \
    bash "$GATE" "$@" > "$out" 2>&1 || rc=$?
  echo "$rc"
}

run_script() {
  # run_script <script> <outfile> <scandir> <allowlist> [args…] ; echoes the code
  local script="$1" out="$2" scandir="$3" allow="$4"
  shift 4
  local rc=0
  TEST_ENV_LEAK_SCANDIR="$scandir" TEST_ENV_LEAK_ALLOWLIST="$allow" \
    bash "$script" "$@" > "$out" 2>&1 || rc=$?
  echo "$rc"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TREE="$TMP/tree"
mkdir -p "$TREE"
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
: > "$TMP/allow-empty"

echo "test-env-leak-gate.test.sh"
echo

# ── 1. the gate parses at all ────────────────────────────────────────────────
if bash -n "$GATE" 2>"$TMP/syn"; then
  ok "1. the gate is syntactically valid bash"
else
  no "1. the gate does not parse: $(cat "$TMP/syn")"
fi

# ── 2. an UNRESTORED put_env reds, naming file AND line ──────────────────────
# This is the shape of the incident: two tests in
# write_hotpath_telemetry_test.exs set :plugins with no on_exit, and a bare
# `use ExUnit.Case` module running next in an unlucky seed inherited it.
cat > "$TREE/leak_test.exs" <<'EX'
defmodule LeakTest do
  use ExUnit.Case

  test "sets a global plugin list and never puts it back" do
    Application.put_env(:barkpark, :plugins, [SlowGatePlugin])
    assert Barkpark.Plugins.Registry.declared() != []
  end
end
EX

rc="$(run_gate "$TMP/o2" "$TREE" "$TMP/allow-empty")"
if [ "$rc" != 0 ] && grep -q "leak_test.exs:5" "$TMP/o2"; then
  ok "2. an unrestored put_env reds (exit $rc) naming leak_test.exs:5"
else
  no "2. an unrestored put_env did not red by file:line (exit $rc)"
  sed 's/^/        /' "$TMP/o2" >&2
fi

# ── 3. the SAME fixture with an on_exit restore GREENS ───────────────────────
# Without this case a gate that flagged every put_env unconditionally would
# satisfy case 2 while measuring nothing. This is the anti-vacuity pair.
cat > "$TREE/leak_test.exs" <<'EX'
defmodule LeakTest do
  use ExUnit.Case

  test "sets a global plugin list and puts it back" do
    prev = Application.get_env(:barkpark, :plugins)
    Application.put_env(:barkpark, :plugins, [SlowGatePlugin])
    on_exit(fn -> Application.put_env(:barkpark, :plugins, prev) end)
    assert Barkpark.Plugins.Registry.declared() != []
  end
end
EX

rc="$(run_gate "$TMP/o3" "$TREE" "$TMP/allow-empty")"
if [ "$rc" = 0 ]; then
  ok "3. the same fixture WITH an on_exit restore greens — the gate reads the pairing, not the keyword"
else
  no "3. a correctly restored put_env reddened (exit $rc) — the gate over-matches, and case 2 proves nothing"
  sed 's/^/        /' "$TMP/o3" >&2
fi

# ── 3b. a CASE TEMPLATE that restores in on_exit credits its users ───────────
# The fourth idiom, and the one a per-file scanner is structurally blind to.
# RegistryCase ends its `using` quote with a real after-each-test on_exit, so
# its users genuinely get :plugins back.
mkdir -p "$TREE/support"
cat > "$TREE/support/good_case.ex" <<'EX'
defmodule GoodCase do
  defmacro __using__(_) do
    quote do
      setup do
        on_exit(fn -> Application.delete_env(:barkpark, :plugins) end)
        :ok
      end
    end
  end
end
EX
cat > "$TREE/leak_test.exs" <<'EX'
defmodule TemplateUserTest do
  use ExUnit.Case
  use GoodCase

  test "leans on the template's on_exit" do
    Application.put_env(:barkpark, :plugins, [SomePlugin])
    assert true
  end
end
EX
rc="$(run_gate "$TMP/o3b" "$TREE" "$TMP/allow-empty")"
if [ "$rc" = 0 ]; then
  ok "3b. a case template's on_exit credits whoever \`use\`s it — the fourth idiom is understood"
else
  no "3b. a template-restored mutation reddened (exit $rc) — case-template credit is not firing"
  sed 's/^/        /' "$TMP/o3b" >&2
fi

# ── 3c. …but a template that only RESETS IN SETUP credits NOBODY ─────────────
# THE ASYMMETRY IS THE WHOLE INCIDENT. DataCase resets :plugins in `setup` —
# BEFORE its own tests — which protects DataCase's suite and protects nobody
# else. If this case ever greens, the gate has been taught to excuse exactly the
# bug it was built for.
cat > "$TREE/support/good_case.ex" <<'EX'
defmodule GoodCase do
  defmacro __using__(_) do
    quote do
      setup do
        Application.put_env(:barkpark, :plugins, [])
        :ok
      end
    end
  end
end
EX
rc="$(run_gate "$TMP/o3c" "$TREE" "$TMP/allow-empty")"
if [ "$rc" != 0 ] && grep -q "leak_test.exs:6" "$TMP/o3c"; then
  ok "3c. a template that only RESETS IN SETUP credits nobody — the incident's asymmetry is preserved"
else
  no "3c. a setup-only template pardoned a leak (exit $rc) — the gate now excuses the exact bug it exists for"
  sed 's/^/        /' "$TMP/o3c" >&2
fi
rm -rf "$TREE/support"
# Reset the shared fixture: 3c deliberately left it leaking, and case 4 asserts
# on a CLEAN tree plus its own file.
cat > "$TREE/leak_test.exs" <<'EX'
defmodule CleanTest do
  use ExUnit.Case
  test "nothing global here" do
    assert 1 + 1 == 2
  end
end
EX

# ── 3d. a restore performed by a CALLED support module credits the caller ────
# The fifth idiom, introduced tree-wide by #14414:
#     prior = Barkpark.PluginEnv.capture()
#     Application.put_env(:barkpark, :plugins, [X])
#     on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)
# The on_exit body contains NO Application call — the restore is a remote call
# into a support module. Reading the calling file alone, this looks unrestored;
# it flagged 12 sites across three files that were all correct.
mkdir -p "$TREE/support"
cat > "$TREE/support/plug_env.ex" <<'EX'
defmodule Barkpark.PlugEnv do
  def capture, do: Application.get_env(:barkpark, :plugins, :unset)
  def restore(:unset), do: Application.delete_env(:barkpark, :plugins)
  def restore(prior), do: Application.put_env(:barkpark, :plugins, prior)
end
EX
cat > "$TREE/leak_test.exs" <<'EX'
defmodule CalledRestoreTest do
  use ExUnit.Case
  alias Barkpark.PlugEnv

  test "restores through a called support module" do
    prior = PlugEnv.capture()
    Application.put_env(:barkpark, :plugins, [SomePlugin])
    on_exit(fn -> PlugEnv.restore(prior) end)
    assert true
  end
end
EX
rc="$(run_gate "$TMP/o3d" "$TREE" "$TMP/allow-empty")"
if [ "$rc" = 0 ]; then
  ok "3d. a restore via a CALLED support module credits the caller — the fifth idiom is understood"
else
  no "3d. a support-module restore reddened (exit $rc) — 12 correct tests would be baselined as leaks"
  sed 's/^/        /' "$TMP/o3d" >&2
fi

# ── 3e. …but calling a module that does NOT restore credits NOTHING ──────────
# The credit must come from what the called module actually DOES, not from the
# mere presence of a call inside on_exit.
cat > "$TREE/support/plug_env.ex" <<'EX'
defmodule Barkpark.PlugEnv do
  def capture, do: Application.get_env(:barkpark, :plugins, :unset)
  def restore(_prior), do: :ok
end
EX
rc="$(run_gate "$TMP/o3e" "$TREE" "$TMP/allow-empty")"
if [ "$rc" != 0 ] && grep -q "leak_test.exs:7" "$TMP/o3e"; then
  ok "3e. calling a module that restores NOTHING credits nothing — the credit tracks behaviour, not syntax"
else
  no "3e. a no-op 'restore' pardoned a real leak (exit $rc) — any call inside on_exit would launder a leak"
  sed 's/^/        /' "$TMP/o3e" >&2
fi
rm -rf "$TREE/support"
cat > "$TREE/leak_test.exs" <<'EX'
defmodule CleanTest do
  use ExUnit.Case
  test "nothing global here" do
    assert 1 + 1 == 2
  end
end
EX

# ── 4. a `try … after` restore in the same test block also greens ────────────
cat > "$TREE/after_test.exs" <<'EX'
defmodule AfterTest do
  use ExUnit.Case

  test "restores in an after clause" do
    original = :persistent_term.get(:snap)
    :persistent_term.put(:snap, :poisoned)

    try do
      assert :persistent_term.get(:snap) == :poisoned
    after
      :persistent_term.put(:snap, original)
    end
  end
end
EX

rc="$(run_gate "$TMP/o4" "$TREE" "$TMP/allow-empty")"
if [ "$rc" = 0 ]; then
  ok "4. a try/after restore in the same block greens — the second real idiom is understood"
else
  no "4. a try/after restore reddened (exit $rc)"
  sed 's/^/        /' "$TMP/o4" >&2
fi

# ── 4b. …but a SIBLING test's after clause must NOT pardon a leak ────────────
# Scoping try/after module-wide silently pardoned two real leaks in
# registry_cache_test.exs, because three neighbouring tests each cleaned up.
cat > "$TREE/after_test.exs" <<'EX'
defmodule AfterTest do
  use ExUnit.Case

  test "restores in an after clause" do
    original = :persistent_term.get(:snap)
    :persistent_term.put(:snap, :poisoned)

    try do
      assert :persistent_term.get(:snap) == :poisoned
    after
      :persistent_term.put(:snap, original)
    end
  end

  test "poisons the very same key and never puts it back" do
    :persistent_term.put(:snap, :leaked)
    assert :persistent_term.get(:snap) == :leaked
  end
end
EX

rc="$(run_gate "$TMP/o4b" "$TREE" "$TMP/allow-empty")"
if [ "$rc" != 0 ] && grep -q "after_test.exs:16" "$TMP/o4b"; then
  ok "4b. a neighbour's after clause does NOT pardon a leaking sibling (after_test.exs:16)"
else
  no "4b. a sibling test's try/after pardoned a real leak (exit $rc) — the scope is module-wide, which is the bug"
  sed 's/^/        /' "$TMP/o4b" >&2
fi
rm -f "$TREE/after_test.exs"

# ── 5. an allowlist row with NO reason is REFUSED ────────────────────────────
cat > "$TREE/leak_test.exs" <<'EX'
defmodule LeakTest do
  use ExUnit.Case

  test "leaks" do
    Application.put_env(:barkpark, :plugins, [SlowGatePlugin])
    assert true
  end
end
EX

printf '1\tleak_test.exs\t:barkpark/:plugins\n' > "$TMP/allow-bare"
rc="$(run_gate "$TMP/o5" "$TREE" "$TMP/allow-bare")"
if [ "$rc" != 0 ] && grep -qi "reason" "$TMP/o5"; then
  ok "5. an allowlist row with no reason is REFUSED (exit $rc)"
else
  no "5. a reasonless allowlist row was accepted (exit $rc) — the allowlist is a mute button"
  sed 's/^/        /' "$TMP/o5" >&2
fi

# ── 6. a reason too short to BE a reason is REFUSED ──────────────────────────
printf '1\tleak_test.exs\t:barkpark/:plugins\ttodo\n' > "$TMP/allow-short"
rc="$(run_gate "$TMP/o6" "$TREE" "$TMP/allow-short")"
if [ "$rc" != 0 ] && grep -qi "reason is" "$TMP/o6"; then
  ok "6. a one-word reason is REFUSED — \"todo\" is a bare row wearing a costume"
else
  no "6. a one-word reason was accepted (exit $rc)"
  sed 's/^/        /' "$TMP/o6" >&2
fi

# ── 6b. a PLACEHOLDER reason is REFUSED, even though it is long enough ───────
# `--baseline` writes "TODO: state why this leak is tolerated" — 38 characters,
# comfortably past MIN_REASON. Without this check a generated baseline could be
# committed unread and every row would carry a "reason" that justifies nothing.
printf '1\tleak_test.exs\t:barkpark/:plugins\tTODO: state why this leak is tolerated\n' > "$TMP/allow-todo"
rc="$(run_gate "$TMP/o6b" "$TREE" "$TMP/allow-todo")"
if [ "$rc" != 0 ] && grep -qi "placeholder" "$TMP/o6b"; then
  ok "6b. a long-enough PLACEHOLDER reason is REFUSED — a generated baseline cannot be committed unread"
else
  no "6b. the --baseline placeholder was accepted as a reason (exit $rc) — the requirement is defeated by its own tool"
  sed 's/^/        /' "$TMP/o6b" >&2
fi

# ── 6c. …and the gate's OWN --baseline output must trip 6b ───────────────────
# Not a hypothetical string: generate a real baseline from the fixture tree and
# prove the gate refuses it. If --baseline ever stops emitting a placeholder,
# this case reds and tells you the safety net is gone.
run_gate "$TMP/o6c-gen" "$TREE" "$TMP/allow-empty" --baseline > /dev/null 2>&1 || true
grep -v '^#' "$TMP/o6c-gen" | grep -v '^$' > "$TMP/allow-generated" || true
if [ -s "$TMP/allow-generated" ]; then
  rc="$(run_gate "$TMP/o6c" "$TREE" "$TMP/allow-generated")"
  if [ "$rc" != 0 ] && grep -qi "placeholder" "$TMP/o6c"; then
    ok "6c. the gate REFUSES its own --baseline output until a human writes the reasons"
  else
    no "6c. a freshly generated baseline was accepted verbatim (exit $rc) — --baseline is a rubber stamp"
    sed 's/^/        /' "$TMP/o6c" >&2
  fi
else
  no "6c. --baseline emitted no rows over a tree with a known leak — it cannot be exercised"
fi

# ── 7. a properly reasoned row DOES pardon (the ratchet grandfathers) ────────
printf '1\tleak_test.exs\t:barkpark/:plugins\tpre-existing, filed as task-fixture-row\n' > "$TMP/allow-good"
rc="$(run_gate "$TMP/o7" "$TREE" "$TMP/allow-good")"
if [ "$rc" = 0 ]; then
  ok "7. a reasoned allowlist row pardons — the gate lands green and ratchets, it does not demand zero"
else
  no "7. a reasoned allowlist row did not pardon (exit $rc) — this gate would red main on day one"
  sed 's/^/        /' "$TMP/o7" >&2
fi

# ── 7b. …and the count is a CEILING: a second leak on the same key still reds ─
cat > "$TREE/leak_test.exs" <<'EX'
defmodule LeakTest do
  use ExUnit.Case

  test "leaks" do
    Application.put_env(:barkpark, :plugins, [SlowGatePlugin])
    assert true
  end

  test "leaks again" do
    Application.put_env(:barkpark, :plugins, [OtherPlugin])
    assert true
  end
end
EX
rc="$(run_gate "$TMP/o7b" "$TREE" "$TMP/allow-good")"
if [ "$rc" != 0 ] && grep -q "allowlisted 1" "$TMP/o7b"; then
  ok "7b. a SECOND leak on an allowlisted key still reds — the row is a ceiling, not an amnesty"
else
  no "7b. a grown count slipped past the allowlist (exit $rc)"
  sed 's/^/        /' "$TMP/o7b" >&2
fi

# ── 8. a population of ZERO scanned files REFUSES ────────────────────────────
# "A floor computed from the tree agrees with a gutted tree by construction."
# The same logic applies to the population: printing OK over a scan of nothing
# is the loudest possible vacuous green.
rc="$(run_gate "$TMP/o8" "$EMPTY" "$TMP/allow-empty")"
if [ "$rc" != 0 ] && grep -qi "zero" "$TMP/o8"; then
  ok "8. a population of ZERO files REFUSES (exit $rc) — an empty scan is a failure, not a pass"
else
  no "8. an empty population produced a verdict (exit $rc) — the gate greens over a tree it never read"
  sed 's/^/        /' "$TMP/o8" >&2
fi

# ── 9. a MISSING population directory REFUSES ────────────────────────────────
rc="$(run_gate "$TMP/o9" "$TMP/does-not-exist" "$TMP/allow-empty")"
if [ "$rc" != 0 ]; then
  ok "9. a missing population directory REFUSES (exit $rc), never skips"
else
  no "9. a missing population directory exited 0 — the gate certifies a tree that is not there"
  sed 's/^/        /' "$TMP/o9" >&2
fi

# ── 10. an UNPARSEABLE file REFUSES BY NAME ─────────────────────────────────
cat > "$TREE/leak_test.exs" <<'EX'
defmodule CleanTest do
  use ExUnit.Case
  test "nothing global here" do
    assert 1 + 1 == 2
  end
end
EX
printf 'defmodule Broken do\n  test "x" do\n    assert (((\n' > "$TREE/broken_test.exs"
rc="$(run_gate "$TMP/o10" "$TREE" "$TMP/allow-empty")"
if [ "$rc" != 0 ] && grep -q "broken_test.exs" "$TMP/o10"; then
  ok "10. an unparseable file REFUSES by name (exit $rc) — never a silent skip"
else
  no "10. an unparseable file was skipped silently (exit $rc) — the scanner reports a tree it never read"
  sed 's/^/        /' "$TMP/o10" >&2
fi
rm -f "$TREE/broken_test.exs"

# ── 11. a MISSING allowlist REFUSES ─────────────────────────────────────────
rc="$(run_gate "$TMP/o11" "$TREE" "$TMP/no-such-allowlist")"
if [ "$rc" != 0 ]; then
  ok "11. a missing allowlist REFUSES (exit $rc) — the floor is committed rows or nothing"
else
  no "11. a missing allowlist exited 0 (exit $rc) — the floor silently became zero"
  sed 's/^/        /' "$TMP/o11" >&2
fi

# ── 12. THE FAIL-BEFORE PROOF: a GUTTED copy of the gate must fail this suite ─
# Delete the detection and every green case above stays green. If a gutted gate
# still passes case 2, this whole file measures nothing.
#
# Three things are asserted, in order, because a mutation that did not apply —
# or that broke the script outright — is not a catch:
#   12a the mutation textually APPLIED (the copy differs from the original);
#   12b the gutted copy still RUNS (exit 0 on a tree with no leaks) — it is a
#       working script that simply cannot see, not a syntax error;
#   12c case 2 re-run against the gutted copy comes back GREEN, which is the
#       failure this suite exists to detect.
GUTTED="$TMP/gutted-gate.sh"
sed 's|Cover.covered?(sig, effective)|true|' "$GATE" > "$GUTTED"

if ! cmp -s "$GATE" "$GUTTED"; then
  ok "12a. the gutting mutation APPLIED — the gutted copy differs from the gate"

  cat > "$TREE/leak_test.exs" <<'EX'
defmodule CleanTest do
  use ExUnit.Case
  test "nothing global here" do
    assert 1 + 1 == 2
  end
end
EX
  rc="$(run_script "$GUTTED" "$TMP/o12b" "$TREE" "$TMP/allow-empty")"
  if [ "$rc" = 0 ]; then
    ok "12b. the gutted copy still RUNS (exit 0 on a clean tree) — it is blind, not broken"
  else
    no "12b. the gutted copy did not run (exit $rc) — the mutation broke the script, so 12c proves nothing"
    sed 's/^/        /' "$TMP/o12b" >&2
  fi

  cat > "$TREE/leak_test.exs" <<'EX'
defmodule LeakTest do
  use ExUnit.Case

  test "sets a global plugin list and never puts it back" do
    Application.put_env(:barkpark, :plugins, [SlowGatePlugin])
    assert Barkpark.Plugins.Registry.declared() != []
  end
end
EX
  rc="$(run_script "$GUTTED" "$TMP/o12c" "$TREE" "$TMP/allow-empty")"
  if [ "$rc" = 0 ]; then
    ok "12c. the gutted copy GREENS on the case-2 fixture — case 2 therefore measures the detector, not the weather"
  else
    no "12c. the gutted copy still reddened (exit $rc) — case 2 is passing for some other reason and proves nothing about the detector"
    sed 's/^/        /' "$TMP/o12c" >&2
  fi
else
  no "12a. the gutting mutation did NOT apply — the sed target has drifted; case 12 is vacuous, fix the pattern"
fi

# ── 13. the gate's own --selftest passes ────────────────────────────────────
rc=0
bash "$GATE" --selftest > "$TMP/o13" 2>&1 || rc=$?
if [ "$rc" = 0 ] && grep -q "SELFTEST PASSED" "$TMP/o13"; then
  ok "13. the gate's own --selftest passes all arms"
else
  no "13. the gate's --selftest failed (exit $rc)"
  sed 's/^/        /' "$TMP/o13" >&2
fi

# ── 14. the REAL tree is a real population ──────────────────────────────────
# Not a leak count — a POPULATION check. If api/test ever stops being reachable
# from this script, every case above still passes against temp fixtures while
# the gate measures nothing in CI. This is the one case that reads the repo.
rc=0
bash "$GATE" --list > "$TMP/o14" 2>&1 || rc=$?
scanned="$(awk '/^scanned /{print $2}' "$TMP/o14")"
if [ "$rc" = 0 ] && [ -n "${scanned:-}" ] && [ "$scanned" -ge 500 ]; then
  ok "14. the real api/test population is $scanned files — the gate is pointed at the suite, not at nothing"
else
  no "14. the real population read as '${scanned:-<none>}' (exit $rc) — the gate has lost sight of api/test"
  sed 's/^/        /' "$TMP/o14" >&2
fi

# ── 15. the committed allowlist is well-formed on the real tree ─────────────
rc=0
bash "$GATE" > "$TMP/o15" 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
  ok "15. the committed allowlist holds the real tree at or below its floor"
else
  no "15. the gate reds on the real tree with the committed allowlist (exit $rc)"
  sed 's/^/        /' "$TMP/o15" >&2
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) cases" >&2
  exit 1
fi
echo "PASSED: $pass of $pass cases"
