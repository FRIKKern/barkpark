defmodule Barkpark.PdsWindowSentinelTest do
  @moduledoc """
  The door for `scripts/pds-window-sentinel_test.sh` — the offline harness that
  pins PDS-D717's retirement of D193 leg (ii).

  This rider is what makes that harness a GATE rather than a script someone
  might remember to run. The door census (`scripts/pds-door-census.sh`) refuses
  to let a green, credential-free, sub-second instrument sit in a disposition
  holding pen, and it is right to: PRICE, ENVIRONMENT, NOT-YET-BUILT,
  CONTENT-RED and RED-BY-DESIGN-REPORTER all describe reasons an instrument
  CANNOT be gated, and none of them is true here.
  """
  use ExUnit.Case, async: true

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic:
  # scripts/elixir-path-escape-check.sh resolves exactly these literals to build
  # the path set elixir.yml dispatches on. Without it a PR touching ONLY the
  # sentinel or its harness would compute changes.outputs.test == 'false' and
  # mix-test would be LEGITIMATELY skipped on the very PR that changed it.
  @harness_rel "../../../scripts/pds-window-sentinel_test.sh"

  setup_all do
    harness = Path.expand(@harness_rel, __DIR__)

    unless File.regular?(harness) do
      flunk(
        "the gate is pointed at nothing: #{harness} does not exist. Do not skip this test — " <>
          "a skip here is a green fixture executed by nothing. Fix the path or delete the " <>
          "instrument, but never both quietly."
      )
    end

    bash =
      System.find_executable("bash") ||
        flunk(
          "the gate is pointed at nothing: no `bash` executable on PATH, so the sentinel " <>
            "harness cannot be run. Failing loud rather than skipping."
        )

    {:ok, harness: harness, bash: bash, root: Path.expand("../../..", __DIR__)}
  end

  test "the sentinel's leg-(ii) retirement harness is GREEN", ctx do
    {out, rc} = System.cmd(ctx.bash, [ctx.harness], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 0,
           "expected `bash #{@harness_rel}` to exit 0, got #{rc}. Its arms are two-sided by " <>
             "construction: three MOVE with PDS-D717 (the wave-10 draw fires, no ii:vmswap " <>
             "refusal is logged, a raised swap ceiling is no longer refused) and five are " <>
             "INVARIANT controls (VmSwap still recorded, legs (i)/(iii)/(iv) still refuse, the " <>
             "floor still tightens only). A red in the first group means leg (ii) came back; a " <>
             "red in the second means retiring it disarmed something else.\n#{out}"

    assert out =~ "pds-window-sentinel_test: PASS",
           "the harness exited 0 without printing its PASS line — an exit code that does not " <>
             "descend from the arms is not a receipt.\n#{out}"
  end

  # The sentinel is reached through ctx.root rather than an @attribute on
  # purpose. An attribute-bound literal would declare it as its own door, and
  # the door census then requires an exec its leg-A detector recognises — a
  # binding it cannot see is an ERROR ("attribute-bound but executed by
  # nothing"), which is a worse state than not declaring it. The harness above
  # sources the sentinel, so a change to EITHER file dispatches this suite
  # through the harness entry.
  #
  # This arm also pins the fact `scripts/pds-door-census.sh:321` currently gets
  # wrong. That row cites `:48-49` and concludes the sentinel "declares only
  # `watch` and `preflight` verbs" — but line 47 declares `sample`, and `sample`
  # is the DEFAULT (`local cmd="${1:-sample}"`). The cited window excludes the
  # line that refutes the claim. Correcting the row belongs to its own task; what
  # belongs HERE is a check that fails if anyone "fixes" the source to match the
  # false claim. Filed as task-2a8524af7df9eb4b.
  test "the sentinel's usage names all THREE verbs, and --help exits clean", ctx do
    {out, rc} =
      System.cmd(ctx.bash, [ctx.sentinel, "--help"], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 0,
           "expected `scripts/pds-window-sentinel.sh --help` to exit 0, got #{rc}.\n#{out}"

    for verb <- ~w(sample watch preflight) do
      assert out =~ verb,
             "the usage block no longer names the `#{verb}` verb. All three are dispatched at " <>
               "the `case \"$cmd\"` in main/0, and `sample` is the DEFAULT — a usage block that " <>
               "omits a live verb is how the door census came to record a false reason.\n#{out}"
    end
  end
end
