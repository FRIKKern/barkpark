defmodule Barkpark.PdsRecordParityTest do
  @moduledoc """
  The PDS record-parity arm (`scripts/pds-record-parity.sh`) ships with its own
  two-sided mutation harness (`scripts/pds-record-parity.test.sh`) and, until
  now, no job that ran it. This case is that job: `api/test/**` rides the
  already-required `Elixir gate` context, so an ExUnit case that shells the
  harness wires the instrument to a required gate without touching a single
  byte of `.github/`.

  ## The honest sentence

  3 of 19 instruments run under a required gate, on every PR that could affect
  them -- NOT on every PR; and record-parity's harness is HERMETIC (zero of its
  checks read a live ledger row, and none reads the epic's real charter either),
  so it gates the ARM's own logic against regression, NOT the epic's record.

  THE CHARTER EXCLUSION IS DELIBERATE, NOT AN OVERSIGHT. Axis A's uniqueness leg
  carries a baseline of the D-numbers the charter defines twice, and that
  baseline goes stale the moment a wave lands a new collision -- which it does
  roughly every wave, because a wave's REVIEW block and the next wave's DECIDE
  block allocate from one next-number pointer. A stale baseline that RED A
  REQUIRED GATE would be "repaired" by deleting the baseline inside a day. So
  the staleness finding stays a hand-run verb and this gate protects the arm's
  logic instead.

  That second clause is the whole caveat and it is not a footnote. The harness
  runs in a `mktemp -d` that is not even a git repo, with no `gh`, no network to
  the ledger and no credentials — by design, because a fixture that reached the
  live ledger would prove nothing about the arm's own code. So a green here
  means "the arm's extraction, status-scoring and disposition logic still
  behaves as pinned". It does NOT mean the epic's record is in parity. Nothing
  in CI checks that; the live run is still a hand-run verb.

  ## Why the assertion is on prose, never on the check count

  The harness's verdict is `PASS  <N> checks, 0 failures`. `N` is 108 today (it
  was 76 before the wave-47 citation-resolver repair added the heading-lens and
  uniqueness arms) and moves every time somebody adds an honest fixture — the
  most likely innocent reason for this case to red.
  `pds-w28-census-check-count-citations-stale` is the standing lesson: counts
  move, prose is the contract. The regex below accepts any count and pins only
  `PASS` and `0 failures`.

  ## Why `bash …` and not `sh` or an exec

  The harness is `#!/usr/bin/env bash` and uses bash-only constructs. It is
  invoked through `bash` explicitly so the executable bit and the host's `sh`
  are both out of the picture.

  `async: false`: the case shells a subprocess that writes fixture trees into a
  temp dir and burns ~1.4 s of CPU; it has no business racing the async lane.
  """
  use ExUnit.Case, async: false

  # Measured 1.30–1.47 s USER CPU, but it is ~80 subprocess invocations: under a
  # loaded CI runner the WALL time is the thing that moves, and ExUnit's default
  # is 60 s. Generous headroom is cheaper than a runner-speed flake.
  @moduletag timeout: 300_000

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic:
  # scripts/elixir-path-escape-check.sh resolves exactly these literals to build
  # the path set elixir.yml dispatches on. Without it (and its matching
  # ELIXIR_TEST_ONLY_PATHS entry) a PR touching ONLY the harness would compute
  # changes.outputs.test == 'false' and mix-test would be LEGITIMATELY skipped
  # on the very PR that changed it.
  @harness_rel "../../../scripts/pds-record-parity.test.sh"

  setup_all do
    harness = Path.expand(@harness_rel, __DIR__)

    unless File.regular?(harness) do
      flunk(
        "the gate is pointed at nothing: #{harness} does not exist. " <>
          "Do not skip this test — a skip here is D26 (green fixtures executed by nothing). " <>
          "Fix the path or delete the instrument, but never both quietly."
      )
    end

    bash =
      System.find_executable("bash") ||
        flunk(
          "the gate is pointed at nothing: no `bash` executable on PATH, so the record-parity " <>
            "mutation harness cannot be run. Failing loud rather than skipping."
        )

    {:ok, harness: harness, bash: bash, root: Path.expand("../../..", __DIR__)}
  end

  test "the record-parity mutation harness is GREEN", ctx do
    {out, rc} = System.cmd(ctx.bash, [ctx.harness], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 0,
           "expected `bash #{@harness_rel}` to exit 0, got #{rc}. Its fixtures are two-sided: " <>
             "the green ones catch an arm degraded into ALWAYS-RED, the red ones catch an arm " <>
             "degraded into ALWAYS-GREEN.\n#{out}"

    assert out =~ ~r/PASS\s+\d+ checks, 0 failures/,
           "the harness exited 0 without printing its own verdict line — an exit code alone is " <>
             "not a receipt (the epic's law since wave 22). Output:\n#{out}"
  end

  # A `PASS N checks` line is a claim about a harness, not about WHICH arms that
  # harness still has. Deleting a whole fixture section lowers N and keeps the
  # verdict line word-for-word identical — and N is deliberately unpinned above,
  # for good reasons that also make that deletion invisible. So the two arms
  # added by the wave-47 repair are named here, on the harness's own prose:
  # a section header and two fixture labels, all of them strings the harness
  # prints only when the arm actually ran.
  @wave47_arms [
    {"AXIS A — the uniqueness leg (one D-number, one finding)",
     "the uniqueness leg's fixture section"},
    {"a D defined ONLY as a heading RESOLVES",
     "the heading-form resolution fixture (the six false reds of wave 47)"},
    {"REVERTING the heading lens does NOT disturb the uniqueness leg",
     "the independence proof between the two new legs"}
  ]

  test "the harness still RUNS the wave-47 citation-resolver arms", ctx do
    {out, rc} = System.cmd(ctx.bash, [ctx.harness], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 0, "the harness must be green before its coverage can be asserted.\n#{out}"

    for {needle, what} <- @wave47_arms do
      assert String.contains?(out, needle),
             "the harness no longer runs #{what}. It went green WITHOUT it, which is exactly " <>
               "the shape this arm exists to refuse: a pass that stopped descending from the " <>
               "measurement it claims. Missing line: #{inspect(needle)}"
    end
  end
end
