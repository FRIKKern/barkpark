defmodule Barkpark.PdsHetznerOfflineDoorTest do
  @moduledoc """
  The door for `scripts/pds-live-hetzner-placement-group.sh --selftest-offline`.

  PLACEMENT IS THE POINT. main's required contexts are exactly ["Elixir gate",
  "PR references an active task", "Cloud gate", "Console gate"], and the
  instrument's offline arm was already wired into
  `.github/workflows/shell-harnesses.yml` (the `pds-hetzner-offline` job) — a
  workflow that is NOT one of those four and therefore cannot block a merge.
  This rider is what puts the arm behind a required context: the path is
  declared in `ELIXIR_TEST_ONLY_PATHS` so a PR touching the instrument
  dispatches this suite, and this case `System.cmd`s the arm itself.

  WHICH ARM, STATED EXACTLY, BECAUSE THE SHIPPED CENSUS ROW NAMED THE WRONG ONE.
  The door census disposed this instrument ENVIRONMENT citing `--selftest` rc=3
  "REFUSE — needs one WORKING credential". That is a true fact about a DIFFERENT
  arm. The script's own header at :13 declares `--selftest-offline` "the
  CREDENTIAL-FREE arm; this is the CI-able gate", and it is: it re-execs itself
  with every `HCLOUD_*`/`HETZNER_*` variable stripped, counts what is left,
  prints the count, and exits 0 with no credential and no network. Measured on
  this tree: `--selftest-offline` rc=0, `--selftest` rc=3.

  ENVIRONMENT PREREQS THIS RIDER DOES NOT ASSUME AWAY: bash, python3 (the stub
  server and three inline validators), curl, and the committed fixtures under
  `internal/cli/testdata/pds_live_hetzner_*.json`. The arm re-emits and diffs
  those fixtures, so a one-byte edit to any of them REDS this door — that is a
  feature, and it couples this door to that testdata directory. The coupling is
  NOT covered by the Elixir dispatch set and the widening was deliberately
  REFUSED rather than shipped: `internal/cli/testdata/**` has zero Elixir
  readers, the escape ratchet only scans `api/lib` and `api/test` so it can
  never DEMAND the entry, and nothing would catch its removal. The real hole is
  `.github/workflows/go-tests.yml`, which carries three testdata carve-outs and
  not this one; that file is out of this wave's fence and the gap is filed
  rather than papered over here.

  PRICE (PDS-D648, CPU = user + sys, LABELLED LOCAL): CPU=1.46+1.27=2.73s LOCAL,
  meter = the census's own `--measure`, a bash `times` builtin around
  `LC_ALL=C bash -c`, cpus=10, load1=23.56, 2026-09-11. Three trials gave
  2.48 / 2.43 / 2.73 s CPU at load1 22.55-23.56 — observed band 2.43-2.73 s, a
  12.3 percent spread, HIGH END QUOTED. The figure is LOCAL and is quotable
  against its own load stamp only: this same byte-identical arm has been
  reported at 3.79 / 2.98 / 2.15 / 1.91 / 1.31 / 1.23 s across five earlier
  waves, so every one of those is a stamp, never a baseline, and none of them
  may be pasted forward. No pds door has ever been metered on a GitHub runner;
  this door's own first CI run supplies that budget, and no projection is made
  here.
  """
  use ExUnit.Case, async: true

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic:
  # scripts/elixir-path-escape-check.sh resolves exactly these literals to build
  # the path set elixir.yml dispatches on. Without it a PR touching ONLY the
  # instrument would compute changes.outputs.test == 'false' and mix-test would
  # be LEGITIMATELY skipped on the very PR that changed it — the #9290/#9292
  # defect, twice shipped already.
  @runner_rel "../../../scripts/pds-live-hetzner-placement-group.sh"

  setup_all do
    runner = Path.expand(@runner_rel, __DIR__)

    unless File.regular?(runner) do
      flunk(
        "the gate is pointed at nothing: #{runner} does not exist. Do not skip this test — " <>
          "a skip here is a green fixture executed by nothing. Fix the path or delete the " <>
          "instrument, but never both quietly."
      )
    end

    bash =
      System.find_executable("bash") ||
        flunk(
          "the gate is pointed at nothing: no `bash` executable on PATH, so the hetzner " <>
            "offline arm cannot be run. Failing loud rather than skipping."
        )

    System.find_executable("python3") ||
      flunk(
        "the gate is pointed at nothing: no `python3` on PATH. The offline arm stands up a " <>
          "loopback stub server and three inline validators in python3, so without it the arm " <>
          "cannot run at all. Failing loud rather than skipping — a skipped door is a door " <>
          "nobody notices is shut."
      )

    {:ok, runner: runner, bash: bash, root: Path.expand("../../..", __DIR__)}
  end

  test "the hetzner placement-group runner's CREDENTIAL-FREE arm is GREEN", ctx do
    {out, rc} =
      System.cmd(ctx.bash, [ctx.runner, "--selftest-offline"],
        cd: ctx.root,
        stderr_to_stdout: true
      )

    assert rc == 0,
           "expected `bash #{@runner_rel} --selftest-offline` to exit 0, got #{rc}. This is " <>
             "the credential-free arm and it needs nothing from the host but bash, python3 " <>
             "and curl — a non-zero here is the instrument, not the environment. Note the " <>
             "arms are two-sided by construction: four MUTATION blocks each demand a refusal " <>
             "(a stub bp printing {\"ok\":true}, a piped rc, a pre-apparatus tree, a degraded " <>
             "read) and the deposit block pairs three refusals with a positive control that " <>
             "must still be accepted, so a guard that refuses everything reds too.\n#{out}"

    assert out =~ "hetzner/hcloud variables in this process environment: 0",
           "the arm did not print its scrub receipt. The whole claim of this door is that the " <>
             "green cannot be a credentialed green; without the counted receipt the exit code " <>
             "says nothing about which environment produced it.\n#{out}"

    assert out =~ "PASS    the credential-free arm holds",
           "the arm exited 0 without printing its OFFLINE VERDICT line — an exit code that " <>
             "does not descend from the arms is not a receipt.\n#{out}"
  end

  test "the deposit guard refuses three distinct lies and still accepts a real 404", ctx do
    {out, rc} =
      System.cmd(ctx.bash, [ctx.runner, "--selftest-offline"],
        cd: ctx.root,
        stderr_to_stdout: true
      )

    assert rc == 0, "the arm must be green before its deposit rows mean anything:\n#{out}"

    for row <- [
          "PASS    not-404: REFUSED, nothing written",
          "PASS    not-json: REFUSED, nothing written",
          "PASS    no-error-code: REFUSED, nothing written"
        ] do
      assert out =~ row,
             "the deposit guard stopped refusing a lie it used to refuse: `#{row}` is absent. " <>
               "This is the wave-30 fail-open the arm exists to keep closed.\n#{out}"
    end

    assert out =~ "PASS    healthy: a real-shaped 404 IS deposited",
           "the positive control is gone. WITHOUT IT the three refusals above would pass on a " <>
             "deposit that simply refused everything, which is the same vacuity inverted.\n" <>
             out

    assert out =~ "PASS    re-emitting the manifest over the committed fixtures reproduces it",
           "the arm no longer reproduces the committed manifest from its own emitter, so the " <>
             "internal/cli/testdata/pds_live_hetzner_*.json fixtures are no longer pinned by " <>
             "this door.\n#{out}"
  end
end
