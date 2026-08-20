defmodule Barkpark.PdsElixirCensusTest do
  @moduledoc """
  The PDS Elixir receipt census (`scripts/pds-elixir-receipt-census.exs`) has had
  exit codes since wave 38 and no job that runs them. This case is that job:
  `api/test/**` rides the already-required `Elixir gate` context, so an ExUnit
  case that shells the census wires the instrument to a required gate without
  touching a single byte of `.github/`.

  ## The honest sentence

  Some of this epic's instruments run under a required gate, on every PR that
  could affect THEM -- not on every PR; and record-parity's harness is HERMETIC
  (zero of its checks read a live ledger row), so it gates the ARM's own logic
  against regression, NOT the epic's record.

  THE FRACTION IS DELIBERATELY NOT WRITTEN HERE. It used to read "3 of 19", which
  was true only until #9380 moved the inventory (the door census enters its own
  denominator by design, and says so). `scripts/pds-door-census.sh --check`
  DERIVES both numbers on every run; a copy of them in this moduledoc is a figure
  with no meter behind it, which is the exact defect this case exists to catch.

  The second half of that sentence is the part that is easy to drop. This door
  is cheap and real, and it is not a claim that the epic's record is checked on
  every merge.

  ## Why `System.cmd` and not `Code.require_file`

  The census is a self-running script: it ends in `main(System.argv())` and
  halts with its own exit code, so requiring it would halt the WHOLE ExUnit
  suite at the census's chosen code. It has to be a subprocess.

  ## Why `--selftest` is NOT gated here

  Leaf-metered it cost ~210 s USER CPU across 33 port-child invocations on the
  PDS-D633/D625 run -- illustrative, that run only; the census now DERIVES the
  floor (9 x its own `user cpu`) on its output's one volatile line, so re-read it
  there rather than quoting this paragraph. Either way `--selftest` is
  disqualified on price, not on merit. The arms below buy the same thing the
  selftest's cheap arms buy: the census runs, it can red — twice, on two different
  arms — and it refuses garbage ARGV.

  THE PRICE MOVED WHEN THE FOURTH ARM LANDED, AND THE OLD FIGURE IS NOT REUSED.
  `28,09 s / 28,31 s of CPU per rider run` was metered over TWO trials of THREE
  arms and does not describe four. What was measured here (wave 47, ExUnit's own
  `Finished in` line, one trial each, wall not CPU): 28,9 s for the three arms,
  42,0 s for the four. The added arm is one more full census run over `api/lib`.
  Re-meter before quoting either number for anything else.

  ## Why the assertions are on prose, never on numbers

  `CENSUS OK` and `FAIL  CLASSIFICATION-TOTAL` are the census's own verdict
  sentences. The site/shape counts (16/74/91 today) move whenever the corpus
  moves, which is the most likely innocent reason for this case to red — so
  they are not asserted on (`pds-w28-census-check-count-citations-stale`).

  ## Why the fail-demo runs with `cd: root`

  The corpus glob is CWD-relative, so a mutant executed from its own tmp dir
  censuses an EMPTY tree. This comment used to say that exits 0 — "a vacuous
  green dressed as a fail-demo." BY RUN it exits 2:

      REFUSED: TRUNCATED CORPUS
        corpus is EMPTY — nothing to census
      The census does not report zeros it cannot stand behind. Exit 2.

  `cd: root` is STILL load-bearing — this test asserts `rc == 1`, and 2 is not 1,
  so a tmp-dir mutant reds here either way — but the failure mode it was guarding
  against stopped existing when the census grew its empty-corpus guard, and the
  comment did not notice. A rationale that outlives the behaviour it cites is the
  same defect as a price that outlives its meter.

  `async: false`: each arm shells a subprocess that walks the whole `api/lib`
  tree; it has no business racing the async lane.
  """
  use ExUnit.Case, async: false

  # MEASURED, not guessed (`/usr/bin/time -p` around a shell, 2 trials, load1
  # stamped 1,70 → 1,97): the arms run 12,12 / 12,07 s wall (plain), 13,70 /
  # 11,77 s (mutant) and 2,95 / 3,20 s (refusal). On THIS host at THAT load no arm
  # comes near ExUnit's 60 s default — so this timeout is HEADROOM for a loaded CI
  # runner, not a measured necessity, and saying so is the point. Earlier prose
  # here claimed "~23 s wall per arm", and a wave-46 brief claimed a 73,91 s mutant
  # arm; both are refuted by the run above. Re-meter before quoting either.
  # (api/config/test.exs's 45_000 is the DB checkout timeout — a different thing.)
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

  # THE SECOND MUTANT (PDS-D678, wave 47). Until this wave the census printed
  # `DRIFT vs PDS-D448 (advisory — printed, never enforced)` with FIVE of its
  # eight population rows drifted, on every run, at exit 0. Those rows were
  # re-derived by run and the block is now ARMED (`D448-DRIFT-REFUSES`), so this
  # arm rides the required Elixir gate for the same reason the one above does:
  # an enforcement nothing executes is the shape this case exists to refuse.
  # ONE TOKEN, ON THE RECORDED SIDE: the mutation moves the committed BASELINE,
  # never the tree, so it cannot be confused with an honest lens correction.
  @baseline_from "unrouted: " <> "23"
  @baseline_to "unrouted: 24"

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

    # `cd: ctx.root` IS LOAD-BEARING: the corpus glob is CWD-relative, so a mutant
    # run from its own tmp dir censuses an empty tree and exits 2 (REFUSED:
    # TRUNCATED CORPUS) — not the rc 1 asserted below. See the moduledoc: it is
    # NOT the "exits 0, vacuous green" this comment used to claim.
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

  test "the population baseline REFUSES: a perturbed literal exits 1 with FAIL  D448-DRIFT-REFUSES",
       ctx do
    {out, rc} = mutate_and_run(ctx, @baseline_from, @baseline_to)

    assert rc == 1,
           "a census whose committed population baseline no longer matches the tree exited #{rc}. " <>
             "That is the pre-wave-47 behaviour: five of eight rows printed DRIFT at exit 0 for " <>
             "four waves, which is a gate whose green costs nothing.\n#{out}"

    assert out =~ "FAIL  D448-DRIFT-REFUSES",
           "the mutant exited 1 without naming the arm — the exit code did not descend from the " <>
             "baseline check. Output:\n#{out}"

    assert out =~ "unrouted baseline 24 derived 23",
           "the refusal named no row and no pair of numbers. A verdict that does not say WHICH " <>
             "population moved cannot be repaired by re-derivation. Output:\n#{out}"

    assert out =~ "RE-DERIVE, never re-type",
           "the refusal shipped without the repair instruction, so the cheapest fix a reader can " <>
             "see is editing the literal until it matches — the defect, wearing the guard's " <>
             "name. Output:\n#{out}"
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

  # ONE ANCHORED EDIT, WRITTEN OUTSIDE THE TREE AND RUN FROM THE ROOT. The
  # exactly-once assertion is the same guard the census's own selftest applies to
  # every mutation anchor: at 0 the demo proves nothing, above 1 the mutant
  # rewrites a site nobody reasoned about. `cd: ctx.root` is load-bearing — the
  # corpus glob is CWD-relative, and a mutant run from its own tmp dir censuses an
  # empty tree and exits 2 (REFUSED: TRUNCATED CORPUS), which is not the rc under
  # test. Kept as a helper so a second arm cannot drift from the first one's setup.
  defp mutate_and_run(ctx, from, to) do
    source = File.read!(ctx.census)
    occurrences = length(String.split(source, from)) - 1

    assert occurrences == 1,
           "the mutation anchor #{inspect(from)} occurs #{occurrences}x in the census " <>
             "(expected exactly 1). At 0 this fail-demo proves nothing; above 1 the mutant " <>
             "would rewrite a site this demo never reasoned about. Re-anchor it on a live " <>
             "single-occurrence site rather than deleting the demo."

    dir =
      Path.join(
        System.tmp_dir!(),
        "pds-elixir-census-mutant-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    mutant = Path.join(dir, "pds-elixir-receipt-census.exs")
    File.write!(mutant, String.replace(source, from, to, global: false))

    System.cmd(ctx.elixir, [mutant], cd: ctx.root, stderr_to_stdout: true)
  end
end
