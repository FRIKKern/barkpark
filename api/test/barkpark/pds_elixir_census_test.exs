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

  AND BOTH FIGURES DESCRIBE ARMS RUN ONE AFTER ANOTHER, which stopped being how
  this case runs: the four arms are now spawned CONCURRENTLY from `setup_all`
  (see the comment there), so the module costs roughly ONE arm's wall clock, not
  four. The two figures above are kept because they are what the serial shape
  actually cost and they are the baseline this change is measured against — they
  are not a description of today's run.

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
  #
  # AND THE TOKEN IS DERIVED FROM THE SOURCE, NEVER TRANSCRIBED. This arm shipped
  # `@baseline_from "unrouted: 23"` with a matching `derived 23` assertion below --
  # a bucket count, in the file whose own "Why the assertions are on prose, never
  # on numbers" section forbids exactly that, ON THE REQUIRED ELIXIR GATE. The
  # census's `textual` row moved 104 -> 106 -> 108 in three waves, every move an
  # honest re-derivation; the day `unrouted` does the same, a pinned literal here
  # reds MAIN and accuses a PR whose bytes never touched the census. See
  # `baseline_perturbation/1` below: it reads today's figure out of @rederived and
  # perturbs it by one, so the arm is always exactly one off whatever the tree
  # currently says and can only ever red for the reason it was written for.

  # ## Why the four arms run in setup_all, CONCURRENTLY
  #
  # Each arm is one `elixir` subprocess walking the whole `api/lib` corpus, and
  # nothing about any arm depends on another. Run one after another they cost
  # ~22 s each and, because a subprocess prints nothing while it works, they
  # showed up as the three largest silent gaps in the required Elixir gate's log
  # — 22,7 + 21,9 + 17,8 s, 62,4 s of the run's 111,6 s of >= 10 s gaps
  # (task-18f209f185f5b3f1). They are now spawned TOGETHER here and awaited, so
  # the module costs one arm's wall clock instead of four.
  #
  # WHAT THIS DOES NOT CHANGE: every arm still runs, over the live corpus, from
  # the root, as its own subprocess, and every assertion below still reads that
  # arm's own rc and output. The mutation anchors are still checked for
  # exactly-one occurrence, and that check still fails IN THE ARM'S OWN TEST —
  # `occurrences` is computed here as data and asserted there, so an anchor that
  # drifts still names the arm it broke rather than collapsing all four into one
  # setup_all error.
  #
  # `async: false` still holds: four concurrent corpus walks have no business
  # racing the async lane either.
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

    root = Path.expand("../../..", __DIR__)
    source = File.read!(census)

    {baseline_from, baseline_to, derived, mutated} = baseline_perturbation(source)

    dir =
      Path.join(
        System.tmp_dir!(),
        "pds-elixir-census-mutants-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # rc/out for every arm, gathered in parallel. `plain` and `unknown_flag` run
    # the committed census; `classification` and `baseline` each run a one-token
    # mutant written outside the tree and executed FROM THE ROOT (`cd: root` is
    # load-bearing — the corpus glob is CWD-relative and a tmp-dir mutant
    # censuses an empty tree, exiting 2 REFUSED: TRUNCATED CORPUS).
    arms = [
      plain: fn -> System.cmd(elixir, [census], cd: root, stderr_to_stdout: true) end,
      unknown_flag: fn ->
        System.cmd(elixir, [census, "--not-a-real-flag"], cd: root, stderr_to_stdout: true)
      end,
      classification: fn ->
        mutant = write_mutant(dir, "classification", source, @mutant_from, @mutant_to)
        System.cmd(elixir, [mutant], cd: root, stderr_to_stdout: true)
      end,
      baseline: fn ->
        mutant = write_mutant(dir, "baseline", source, baseline_from, baseline_to)
        System.cmd(elixir, [mutant], cd: root, stderr_to_stdout: true)
      end
    ]

    results =
      arms
      |> Enum.map(fn {name, fun} -> {name, Task.async(fun)} end)
      |> Enum.map(fn {name, task} -> {name, Task.await(task, 540_000)} end)
      |> Map.new()

    {:ok,
     census: census,
     elixir: elixir,
     root: root,
     runs: results,
     anchors: %{
       classification: occurrences(source, @mutant_from),
       baseline: occurrences(source, baseline_from)
     },
     baseline: %{from: baseline_from, derived: derived, mutated: mutated}}
  end

  test "the receipt census runs GREEN over the live corpus", ctx do
    {out, rc} = ctx.runs.plain

    assert rc == 0, "expected `elixir #{@census_rel}` (no flag) to exit 0, got #{rc}:\n#{out}"

    assert out =~ "CENSUS OK",
           "the census exited 0 without printing its own green verdict — an exit code alone is " <>
             "not a receipt (the epic's law since wave 22). Output:\n#{out}"
  end

  test "the gate CAN red: a one-token mutant exits 1 with FAIL  CLASSIFICATION-TOTAL", ctx do
    assert_single_anchor(ctx.anchors.classification, @mutant_from)

    {out, rc} = ctx.runs.classification

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
    assert_single_anchor(ctx.anchors.baseline, ctx.baseline.from)

    {out, rc} = ctx.runs.baseline

    assert rc == 1,
           "a census whose committed population baseline no longer matches the tree exited #{rc}. " <>
             "That is the pre-wave-47 behaviour: five of eight rows printed DRIFT at exit 0 for " <>
             "four waves, which is a gate whose green costs nothing.\n#{out}"

    assert out =~ "FAIL  D448-DRIFT-REFUSES",
           "the mutant exited 1 without naming the arm — the exit code did not descend from the " <>
             "baseline check. Output:\n#{out}"

    assert out =~ "unrouted baseline #{ctx.baseline.mutated} derived #{ctx.baseline.derived}",
           "the refusal named no row and no pair of numbers. A verdict that does not say WHICH " <>
             "population moved cannot be repaired by re-derivation. Expected the pair " <>
             "#{ctx.baseline.mutated}/#{ctx.baseline.derived}, both READ OUT OF the census source " <>
             "rather than typed here. Output:\n#{out}"

    assert out =~ "RE-DERIVE, never re-type",
           "the refusal shipped without the repair instruction, so the cheapest fix a reader can " <>
             "see is editing the literal until it matches — the defect, wearing the guard's " <>
             "name. Output:\n#{out}"
  end

  test "the census REFUSES an unknown flag — ARGV-STRICT, not a shrug", ctx do
    {out, rc} = ctx.runs.unknown_flag

    assert rc == 2,
           "expected the census to REFUSE an unknown flag with exit 2, got #{rc}. A census that " <>
             "swallows ARGV is a census measuring something nobody asked for.\n#{out}"

    assert out =~ "REFUSED: UNKNOWN ARGUMENT", out
    assert out =~ "unknown argument", out
  end

  # THE EXACTLY-ONCE GUARD, unchanged in force and moved in place. It is the same
  # guard the census's own selftest applies to every mutation anchor: at 0 the
  # fail-demo proves nothing, above 1 the mutant rewrites a site nobody reasoned
  # about. It is asserted HERE, in the arm's own test, so a drifted anchor names
  # the arm it broke — the count itself is taken once in setup_all.
  defp assert_single_anchor(count, anchor) do
    assert count == 1,
           "the mutation anchor #{inspect(anchor)} occurs #{count}x in the census " <>
             "(expected exactly 1). At 0 this fail-demo proves nothing; above 1 the mutant " <>
             "would rewrite a site this demo never reasoned about. Re-anchor it on a live " <>
             "single-occurrence site rather than deleting the demo."
  end

  defp occurrences(source, anchor), do: length(String.split(source, anchor)) - 1

  # ONE ANCHORED EDIT, WRITTEN OUTSIDE THE TREE. Each mutant gets its own file so
  # the concurrent arms cannot overwrite one another's source.
  defp write_mutant(dir, name, source, from, to) do
    path = Path.join(dir, "#{name}-pds-elixir-receipt-census.exs")
    File.write!(path, String.replace(source, from, to, global: false))
    path
  end

  # WHAT THE BASELINE ARM PERTURBS, READ OUT OF THE CENSUS RATHER THAN TYPED HERE.
  # Returns the anchor pair for the mutant plus both sides of the comparison the
  # census must then print, so the assertion above names a row and a pair of
  # numbers without this file ever transcribing one. An honest re-derivation of
  # @rederived.unrouted moves all four together and this arm does not notice.
  defp baseline_perturbation(source) do
    case Regex.run(~r/@rederived\s+%\{.*?unrouted:\s*(\d+)/s, source) do
      [_, n] ->
        derived = String.to_integer(n)
        {"unrouted: #{derived}", "unrouted: #{derived + 1}", derived, derived + 1}

      nil ->
        flunk(
          "could not read @rederived.unrouted out of the census source. This arm perturbs that " <>
            "literal; if the attribute was renamed or the key removed, RE-POINT the derivation " <>
            "rather than pinning a number back into this file -- a pinned number is what this " <>
            "arm was repaired to stop carrying."
        )
    end
  end
end
