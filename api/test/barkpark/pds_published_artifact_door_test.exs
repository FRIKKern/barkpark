defmodule Barkpark.PdsPublishedArtifactDoorTest do
  @moduledoc """
  The door for `scripts/pds-published-artifact-door.sh`.

  PLACEMENT IS THE POINT. main's required contexts are exactly ["Elixir gate",
  "PR references an active task", "Cloud gate", "Console gate"], so a js-only
  workflow CANNOT block a merge no matter how correct it is. This rider is what
  puts a shell door behind a required context: the path is declared in
  ELIXIR_TEST_ONLY_PATHS so a PR touching the door dispatches this suite, and
  this case `System.cmd`s the door itself.
  """
  use ExUnit.Case, async: true

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic:
  # scripts/elixir-path-escape-check.sh resolves exactly these literals to build
  # the path set elixir.yml dispatches on. Without it a PR touching ONLY the
  # door would compute changes.outputs.test == 'false' and mix-test would be
  # LEGITIMATELY skipped on the very PR that changed it.
  @door_rel "../../../scripts/pds-published-artifact-door.sh"

  # The selftest is bound and EXECUTED DIRECTLY here rather than reached through
  # `door --selftest`. Both forms run the same arms, but only a direct
  # attribute-bound exec gives the harness its own leg A in the door census —
  # reached only through the door, it enumerates as UNDISPOSED with no class that
  # honestly fits, since a green, credential-free, offline harness is gate-able
  # and every disposition class names a reason an instrument CANNOT be gated.
  @selftest_rel "../../../scripts/pds-published-artifact-door_test.sh"

  setup_all do
    door = Path.expand(@door_rel, __DIR__)

    unless File.regular?(door) do
      flunk(
        "the gate is pointed at nothing: #{door} does not exist. Do not skip this test — " <>
          "a skip here is a green fixture executed by nothing. Fix the path or delete the " <>
          "instrument, but never both quietly."
      )
    end

    bash =
      System.find_executable("bash") ||
        flunk(
          "the gate is pointed at nothing: no `bash` executable on PATH, so the published " <>
            "artifact door cannot be run. Failing loud rather than skipping."
        )

    {:ok, door: door, bash: bash, root: Path.expand("../../..", __DIR__)}
  end

  # THE SELFTEST IS THE GATED ARM, not the live run.
  #
  # The live run against origin/main is RED today and correctly so — main
  # advertises two @barkpark/react subpaths the frozen preview.1 tarball cannot
  # serve. Gating on it would red every PR in the repository for a defect none of
  # them introduced, and it would be the leg that gets weakened. The selftest is
  # hermetic (synthetic fixture, no network, no dependence on this repo's
  # history), so it asserts the door's BEHAVIOUR rather than the tree's state.
  test "the published-artifact door's selftest is GREEN", ctx do
    {out, rc} =
      System.cmd(ctx.bash, [Path.expand(@selftest_rel, __DIR__)],
        cd: ctx.root,
        stderr_to_stdout: true
      )

    assert rc == 0,
           "expected `#{@door_rel} --selftest` to exit 0, got #{rc}. Its arms are two-sided by " <>
             "construction: it must RED on a subpath added after R and GREEN on the same tree " <>
             "without it, and every escape hatch has a MUTATION twin that removes the hatch and " <>
             "demands the same tree refuse. A hatch that skips everything is indistinguishable " <>
             "from a hatch that works.\n#{out}"

    assert out =~ "SELFTEST PASS",
           "the selftest exited 0 without printing its PASS line — an exit code that does not " <>
             "descend from the arms is not a receipt.\n#{out}"
  end

  # THE DOOR MUST BE ABLE TO REFUSE, and today's main is the proof.
  #
  # This is deliberately NOT an assertion that main is clean. It asserts the door
  # still SEES the defect it was built for. If someone bumps @barkpark/react or
  # trims its exports map, this arm goes red — and that red is the signal to
  # re-derive it, not to delete it. A door whose only evidence is a green run has
  # never been shown able to fire.
  test "on real main the door still NAMES the react subpaths it was built to refuse", ctx do
    {out, rc} =
      System.cmd(ctx.bash, [ctx.door, "origin/main"], cd: ctx.root, stderr_to_stdout: true)

    if rc == 0 do
      flunk(
        "the door is GREEN on origin/main. Either @barkpark/react was released (its exports " <>
          "map now rides its own version literal) or the exports map was trimmed — in both " <>
          "cases this arm has done its job and must be RE-DERIVED against the new first " <>
          "positive, never deleted. A door that has never refused is not a door.\n#{out}"
      )
    end

    assert rc == 1, "expected rc 1 (REFUSE) or a re-derivation flunk, got #{rc}.\n#{out}"

    assert out =~ "@barkpark/react",
           "the door refused without naming the package — an unnamed refusal is not " <>
             "actionable.\n#{out}"

    assert out =~ "./client" and out =~ "./paper-surface.css",
           "the door refused @barkpark/react without naming BOTH subpaths the frozen " <>
             "1.0.0-preview.1 artifact cannot serve.\n#{out}"

    assert out =~ "reads the exports MAP only",
           "the run did not print what the door structurally cannot see. Prose that lives only " <>
             "in a comment is what a copy-paste drops, and this door WILL be quoted as proving " <>
             "more than it can.\n#{out}"
  end
end
