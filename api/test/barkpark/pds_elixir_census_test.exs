defmodule Barkpark.PdsElixirCensusTest do
  @moduledoc """
  The PDS Elixir receipt census (`scripts/pds-elixir-receipt-census.exs`) has had
  exit codes since wave 38 and no job that runs them. This case is that job:
  `api/test/**` rides the already-required `Elixir gate` context, so an ExUnit
  case that shells the census wires the instrument to a required gate without
  touching a single byte of `.github/`.

  ## The honest sentence

  3 of 19 instruments run under a required gate, on every PR that could affect
  them -- NOT on every PR; and record-parity's harness is HERMETIC (zero of its
  76 checks read a live ledger row), so it gates the ARM's own logic against
  regression, NOT the epic's record.

  The second half of that sentence is the part that is easy to drop. This door
  is cheap and real, and it is not a claim that the epic's record is checked on
  every merge.

  ## Why `System.cmd` and not `Code.require_file`

  The census is a self-running script: it ends in `main(System.argv())` and
  halts with its own exit code, so requiring it would halt the WHOLE ExUnit
  suite at the census's chosen code. It has to be a subprocess.

  ## Why `--selftest` is NOT gated here

  Leaf-metered it costs ~210 s USER CPU across 33 port-child invocations
  (PDS-D633/D625) — disqualified on price, not on merit. The three arms below
  cost ~23 s wall each and buy the same thing the selftest's cheap arms buy:
  the census runs, it can red, and it refuses garbage ARGV.

  ## Why the assertions are on prose, never on numbers

  `CENSUS OK` and `FAIL  CLASSIFICATION-TOTAL` are the census's own verdict
  sentences. The site/shape counts (16/74/91 today) move whenever the corpus
  moves, which is the most likely innocent reason for this case to red — so
  they are not asserted on (`pds-w28-census-check-count-citations-stale`).

  ## Why the fail-demo runs with `cd: root`

  The corpus glob is CWD-relative. A mutant executed from its own tmp dir would
  census an EMPTY tree and exit 0 — a vacuous green dressed as a fail-demo. The
  mutant runs from the repo root for exactly that reason.

  `async: false`: each arm shells a subprocess that walks the whole `api/lib`
  tree; it has no business racing the async lane.
  """
  use ExUnit.Case, async: false

  # ~23 s wall per arm against ExUnit's 60 s default. Without this the case is a
  # runner-speed flake rather than a gate. (api/config/test.exs's 45_000 is the
  # DB checkout timeout — a different thing entirely.)
  @moduletag timeout: 600_000

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic:
  # scripts/elixir-path-escape-check.sh resolves exactly these literals to build
  # the path set elixir.yml dispatches on. Without it (and its matching
  # ELIXIR_TEST_ONLY_PATHS entry) a PR touching ONLY the census would compute
  # changes.outputs.test == 'false', mix-test would be LEGITIMATELY skipped, and
  # the instrument's own guard would not run on the very PR that changed it.
  # That is not hypothetical: #9290 and #9292 each published `Test (Elixir
  # 1.18.1 / OTP 27.0) :: skipped` for exactly this reason.
  @census_rel "../../../scripts/pds-elixir-receipt-census.exs"

  # A ONE-TOKEN mutant: `tl/1` drops a single classified site, so the emitted
  # population no longer equals classified + unclassified and the census's own
  # CLASSIFICATION-TOTAL check reds. Everything else in the run is untouched.
  @mutant_from "classified = Enum.map(routed" <> ", &classify(&1, index))"
  @mutant_to "classified = tl(Enum.map(routed, &classify(&1, index)))"

  setup_all do
    census = Path.expand(@census_rel, __DIR__)

    unless File.regular?(census) do
      flunk(
        "the gate is pointed at nothing: #{census} does not exist. " <>
          "Do not skip this test — a skip here is D26 (green fixtures executed by nothing). " <>
          "Fix the path or delete the instrument, but never both quietly."
      )
    end

    elixir =
      System.find_executable("elixir") ||
        flunk(
          "the gate is pointed at nothing: no `elixir` executable on PATH, so the receipt " <>
            "census cannot be run. Failing loud rather than skipping."
        )

    {:ok, census: census, elixir: elixir, root: Path.expand("../../..", __DIR__)}
  end

  test "the receipt census runs GREEN over the live corpus", ctx do
    {out, rc} = System.cmd(ctx.elixir, [ctx.census], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 0, "expected `elixir #{@census_rel}` (no flag) to exit 0, got #{rc}:\n#{out}"

    assert out =~ "CENSUS OK",
           "the census exited 0 without printing its own green verdict — an exit code alone is " <>
             "not a receipt (the epic's law since wave 22). Output:\n#{out}"
  end

  test "the gate CAN red: a one-token mutant exits 1 with FAIL  CLASSIFICATION-TOTAL", ctx do
    source = File.read!(ctx.census)

    occurrences = length(String.split(source, @mutant_from)) - 1

    assert occurrences == 1,
           "the mutation anchor #{inspect(@mutant_from)} occurs #{occurrences}x in the census " <>
             "(expected exactly 1). At 0 this fail-demo proves nothing; above 1 the mutant " <>
             "would rewrite a site this demo never reasoned about. Re-anchor it on a live " <>
             "single-occurrence site rather than deleting the demo."

    mutant_dir =
      Path.join(
        System.tmp_dir!(),
        "pds-elixir-census-mutant-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(mutant_dir)
    on_exit(fn -> File.rm_rf!(mutant_dir) end)

    mutant = Path.join(mutant_dir, "pds-elixir-receipt-census.exs")
    File.write!(mutant, String.replace(source, @mutant_from, @mutant_to, global: false))

    # `cd: ctx.root` IS LOAD-BEARING: the corpus glob is CWD-relative, so a
    # mutant run from its own tmp dir would census an empty tree and pass.
    {out, rc} = System.cmd(ctx.elixir, [mutant], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 1,
           "a mutated census exited #{rc}; the census cannot distinguish a site that fell out " <>
             "of the taxonomy from one that did not, which makes the green above vacuous.\n#{out}"

    assert out =~ "FAIL  CLASSIFICATION-TOTAL",
           "the mutant exited 1 without printing FAIL  CLASSIFICATION-TOTAL — the exit code " <>
             "did not descend from the check. Output:\n#{out}"

    assert out =~ "fell out of the taxonomy entirely",
           "the mutant reded without the prose that says WHY — a verdict line with no reason " <>
             "is the shape this epic exists to stop. Output:\n#{out}"
  end

  test "the census REFUSES an unknown flag — ARGV-STRICT, not a shrug", ctx do
    {out, rc} =
      System.cmd(ctx.elixir, [ctx.census, "--not-a-real-flag"],
        cd: ctx.root,
        stderr_to_stdout: true
      )

    assert rc == 2,
           "expected the census to REFUSE an unknown flag with exit 2, got #{rc}. A census that " <>
             "swallows ARGV is a census measuring something nobody asked for.\n#{out}"

    assert out =~ "REFUSED: UNKNOWN ARGUMENT", out
    assert out =~ "unknown argument", out
  end
end
