defmodule Barkpark.PdsMeterRiderTest do
  @moduledoc """
  `tooling/scaffy-duels/meter.py` is the executable half of METER.md, and until
  this case landed NOTHING RAN IT. That is the whole of wave 48's finding: the
  instrument was fast (0,08 s), self-proving (`--self-test` reds on a 1.25x-trap
  fixture), non-vacuous and correct on every envelope it walked -- and it still
  printed `34 envelopes` against a doc that said `24/24`, because zero of 43
  workflow files called it. THE INSTRUMENT IS NOT THE MECHANISM; BEING RUN IS.

  ## Why HERE and not a workflow

  `.github/required-checks.json`'s S4 doctrine disqualifies a workflow carrying a
  workflow-level `on: paths:` filter from ever being REQUIRED -- an absent
  required context reports "expected" forever (D18). So the paths-filtered route
  (`shell-harnesses.yml` and its kin) is an advisory lane wearing a gate's name.
  The only blocking route is the one METER.md §6 names: declare the instrument's
  paths in `ELIXIR_TEST_ONLY_PATHS` (`scripts/elixir-path-escape-check.sh`), so
  elixir.yml's dispatcher runs the test job on any PR that touches them, and put
  the call in an ExUnit case -- which rides the already-required `Elixir gate`
  without touching a byte of `.github/`. Same shape, same reason, as
  `api/test/barkpark/pds_elixir_census_test.exs` next door.

  ## The four "../../../tooling/scaffy-duels/..." STRING LITERALS are load-bearing

  `scripts/elixir-path-escape-check.sh` resolves exactly these literals to build
  the census of repo-root reads, and `--check` reds unless every one of them is
  declared in a dispatched path set. A path constant one binding away from its
  `Path.join` is invisible to that scanner (the census case next door carries the
  measured incident). Written inline, they are what makes the declaration and the
  call provably the same set of paths.

  ## What is asserted, and what a red here means

  Two clean arms (`--self-test`, `verify results/` over the live corpus) and
  THREE MUTANTS, each perturbing a different load-bearing input, each derived
  from the tree rather than transcribed here:

    * `rate` -- the RATES entry for the model the corpus actually uses, +0,01 on
      the input rate. NOTE THE DERIVATION IS THE POINT: the RATES table holds six
      models and this corpus exercises ONE (`claude-sonnet-5`). Perturbing
      `claude-opus-5` by hand was MEASURED to green at rc=0 -- a mutation of a
      row nothing reads is not a fail-demo. The arm reads the model off an
      envelope's own `modelUsage` and perturbs the row that serves it.
    * `population` -- METER.md's `meter:population` marker AND its §2 prose
      literal, both +1, so the doc's declared corpus and the corpus on disk
      disagree by exactly one.
    * `corpus` -- one envelope's `total_cost_usd` x 1.25, which is why
      `tooling/scaffy-duels/results/**` is in the dispatched set: a change under
      that tree can red this gate.

  A red naming `population drift` or a `§3 ... drift` after an honest corpus
  change is METER.md asking to be RE-DERIVED (`meter.py shares results/`), never
  a reason to edit the doc's literals until the numbers agree.

  ## Price, MEASURED on the builder's host

  darwin, `hw.ncpu` 10, load1 11,58 at the time of the meter runs. `--self-test`
  real 0,08-0,09 s / user 0,03 s (n=3, `/usr/bin/time -p`); `verify results/`
  real 0,08 s. The mutants each cost one more `verify` plus a ~612 KB directory
  copy. The module's own price is `Finished in`, quoted in the PR -- not the
  `--slowest` list, which attributes a `setup_all` to no test at all.

  `async: false`: the arms shell subprocesses and write scratch trees; they have
  no business racing the async lane.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 300_000

  @meter_rel "../../../tooling/scaffy-duels/meter.py"
  @doc_rel "../../../tooling/scaffy-duels/METER.md"
  @twin_rel "../../../tooling/scaffy-duels/tally_wf.py"
  @corpus_rel "../../../tooling/scaffy-duels/results"

  @pop_marker_re ~r/<!--\s*meter:population\s+(\d+)\s*-->/
  @pop_prose_re ~r/on\s+(\d+)\/(\d+)\*\*\s+recorded duel envelopes/

  setup_all do
    root = Path.expand("../../..", __DIR__)

    meter = require_file!(@meter_rel, "the metering instrument")
    doc = require_file!(@doc_rel, "the doc whose figures verify asserts")
    _twin = require_file!(@twin_rel, "the mirrored rate table --self-test asserts")
    corpus = require_dir!(@corpus_rel, "the duel-envelope corpus")

    python =
      System.find_executable("python3") ||
        flunk(
          "REFUSING BY NAME: no `python3` executable on PATH, so " <>
            "tooling/scaffy-duels/meter.py cannot be run. This test does NOT skip -- a skip " <>
            "here reproduces the exact defect it was written to end (an instrument nothing " <>
            "executes, reporting green). Install python3 or delete the instrument, never both " <>
            "quietly."
        )

    dir =
      Path.join(System.tmp_dir!(), "pds-meter-mutants-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {rate_from, rate_to, rate_model} = rate_perturbation(meter, corpus)
    {pop_declared, pop_mutated} = population_perturbation(doc)
    {envelope_name, corpus_factor} = {first_envelope_name(corpus), 1.25}

    arms = [
      self_test: fn -> System.cmd(python, [meter, "--self-test"], cd: root, stderr_to_stdout: true) end,
      verify: fn -> System.cmd(python, [meter, "verify", corpus], cd: root, stderr_to_stdout: true) end,
      unknown_command: fn ->
        System.cmd(python, [meter, "--not-a-real-command"], cd: root, stderr_to_stdout: true)
      end,
      rate: fn ->
        scratch = scratch_tree(dir, "rate", meter, doc, corpus)
        patch_file!(scratch.meter, rate_from, rate_to)
        run_scratch(python, scratch)
      end,
      population: fn ->
        scratch = scratch_tree(dir, "population", meter, doc, corpus)
        patch_population!(scratch.doc)
        run_scratch(python, scratch)
      end,
      corpus: fn ->
        scratch = scratch_tree(dir, "corpus", meter, doc, corpus)
        scale_envelope!(Path.join(scratch.corpus, envelope_name), corpus_factor)
        run_scratch(python, scratch)
      end,
      control: fn ->
        # THE CONTROL. An unmutated copy of the same scratch tree, run the same
        # way. Without it, a red in any mutant arm above is equally explained by
        # "the copy itself broke the tool" -- and the three arms would be
        # measuring the copy, not the mutation.
        run_scratch(python, scratch_tree(dir, "control", meter, doc, corpus))
      end
    ]

    results =
      arms
      |> Enum.map(fn {name, fun} -> {name, Task.async(fun)} end)
      |> Enum.map(fn {name, task} -> {name, Task.await(task, 240_000)} end)
      |> Map.new()

    {:ok,
     runs: results,
     meter: meter,
     anchors: %{
       rate: occurrences(File.read!(meter), rate_from),
       population: pop_declared
     },
     rate: %{from: rate_from, to: rate_to, model: rate_model},
     population: %{declared: pop_declared, mutated: pop_mutated},
     corpus: %{envelope: envelope_name, factor: corpus_factor}}
  end

  test "meter.py --self-test is GREEN and prints its own verdict", ctx do
    {out, rc} = ctx.runs.self_test

    assert rc == 0, "`meter.py --self-test` exited #{rc}; expected 0.\n#{out}"

    assert out =~ "self-test OK",
           "the self-test exited 0 without printing its own verdict sentence -- an exit code " <>
             "alone is not a receipt.\n#{out}"
  end

  test "meter.py verify results/ is GREEN over the live corpus and asserts its population", ctx do
    {out, rc} = ctx.runs.verify

    assert rc == 0, "`meter.py verify #{@corpus_rel}` exited #{rc}; expected 0.\n#{out}"

    assert out =~ ~r/meter\.py: \d+ envelopes — \d+ exact/,
           "verify exited 0 without an all-exact population line.\n#{out}"

    assert out =~ ~r/meter\.py: population \d+ — matches METER\.md/,
           "verify exited 0 WITHOUT the population assertion firing. That is the fail-open " <>
             "METER.md §6 names: a run that walks the corpus but never compares it against the " <>
             "doc's declared figure is a gate with no force.\n#{out}"
  end

  test "THE CONTROL: an unmutated scratch copy of the tree still verifies clean", ctx do
    {out, rc} = ctx.runs.control

    assert rc == 0,
           "the UNMUTATED scratch copy exited #{rc}. Every mutant arm below is measured against " <>
             "this copy; if copying the tree alone reds, the three reds prove nothing about the " <>
             "mutations.\n#{out}"
  end

  test "THE GATE CAN RED: a RATES drift on the model the corpus uses", ctx do
    assert_single_anchor(ctx.anchors.rate, ctx.rate.from)

    {out, rc} = ctx.runs.rate

    assert rc == 1,
           "a meter.py whose rate for #{ctx.rate.model} was perturbed (#{ctx.rate.from} -> " <>
             "#{ctx.rate.to}) exited #{rc}. The published cost formula would then be unchecked " <>
             "against the rate table it is computed from.\n#{out}"

    assert out =~ "rates/tier/TTL drift?",
           "the mutant reded without naming rates as the suspect -- a verdict with no reason " <>
             "is the shape this epic exists to refuse.\n#{out}"

    assert out =~ "not all-exact",
           "the mutant reded without METER.md §4's all-exact refusal.\n#{out}"
  end

  test "THE GATE CAN RED: a population-marker drift in METER.md", ctx do
    {out, rc} = ctx.runs.population

    assert rc == 1,
           "METER.md declaring #{ctx.population.mutated} envelopes over a corpus of " <>
             "#{ctx.population.declared} exited #{rc}. That disagreement is exactly what rotted " <>
             "this standard in the first place (the doc said 24/24 while the corpus held 34).\n#{out}"

    assert out =~
             "population drift: the corpus holds #{ctx.population.declared} envelopes, METER.md publishes #{ctx.population.mutated}",
           "the refusal did not name BOTH figures. Both numbers are read out of the tree here, " <>
             "never typed, so this assertion follows an honest corpus growth instead of " <>
             "accusing the PR that grew it.\n#{out}"
  end

  test "THE GATE CAN RED: a corpus drift — one envelope's total_cost_usd x1.25", ctx do
    {out, rc} = ctx.runs.corpus

    assert rc == 1,
           "scaling #{ctx.corpus.envelope}'s total_cost_usd by #{ctx.corpus.factor} exited #{rc}. " <>
             "This is the arm that earns `tooling/scaffy-duels/results/**` its place in the " <>
             "dispatched path set: a change under that tree must be able to red this gate.\n#{out}"

    assert out =~ "#{ctx.corpus.envelope}: sum(modelUsage.costUSD)",
           "the refusal did not name the envelope it broke.\n#{out}"
  end

  test "meter.py REFUSES an unknown command — ARGV-STRICT, not a shrug", ctx do
    {out, rc} = ctx.runs.unknown_command

    assert rc == 2, "expected meter.py to refuse an unknown command with exit 2, got #{rc}.\n#{out}"

    assert out =~ "unknown command", out
  end

  # --- helpers --------------------------------------------------------------

  defp require_file!(rel, what) do
    path = Path.expand(rel, __DIR__)

    if File.regular?(path) do
      path
    else
      flunk(
        "REFUSING BY NAME: #{rel} (#{what}) is not a file at #{path}. The gate is pointed at " <>
          "nothing. Re-point it or retire the instrument -- do not let this pass quietly."
      )
    end
  end

  defp require_dir!(rel, what) do
    path = Path.expand(rel, __DIR__)

    if File.dir?(path) do
      path
    else
      flunk(
        "REFUSING BY NAME: #{rel} (#{what}) is not a directory at #{path}. An absent corpus " <>
          "inside a checkout is a deletion, not a skipped arm."
      )
    end
  end

  # The RATES row to perturb is DERIVED, never transcribed: the corpus's own
  # `modelUsage` key says which model is priced, and `rate_for` in meter.py
  # resolves it by PREFIX in source order, so the first matching key is the row
  # that actually serves this corpus.
  defp rate_perturbation(meter, corpus) do
    source = File.read!(meter)
    model = corpus_model(corpus)

    rows = Regex.scan(~r/"([a-z0-9\-]+)":\s*\(([\d.]+),\s*([\d.]+)\)/, source)

    case Enum.find(rows, fn [_, key, _, _] -> String.starts_with?(model, key) end) do
      [whole, key, rate_in, rate_out] ->
        bumped = bump_decimal(rate_in)

        if bumped == rate_in do
          flunk("could not perturb the input rate #{rate_in} for #{key} -- it did not move.")
        end

        {whole, "\"#{key}\": (#{bumped}, #{rate_out})", model}

      nil ->
        flunk(
          "no RATES row in meter.py serves the corpus model #{inspect(model)}. RE-POINT this " <>
            "derivation rather than pinning a model name here: a mutation of a row the corpus " <>
            "never reads greens at rc=0 and proves nothing (measured -- `claude-opus-5` is such " <>
            "a row today)."
        )
    end
  end

  defp corpus_model(corpus) do
    envelope = Path.join(corpus, first_envelope_name(corpus))

    case envelope |> File.read!() |> Jason.decode!() |> Map.get("modelUsage") do
      %{} = mu when map_size(mu) > 0 -> mu |> Map.keys() |> Enum.sort() |> hd()
      other -> flunk("#{envelope} has no usable modelUsage: #{inspect(other)}")
    end
  end

  defp first_envelope_name(corpus) do
    case corpus |> Path.join("*.agent.json") |> Path.wildcard() |> Enum.sort() do
      [first | _] ->
        Path.basename(first)

      [] ->
        flunk(
          "the corpus at #{corpus} holds no *.agent.json envelope. An empty corpus is a " <>
            "REFUSAL here, never a quietly skipped arm."
        )
    end
  end

  # "3.00" -> "3.01": one step in the LAST decimal place the source itself wrote,
  # so the mutant keeps the literal's shape and the perturbation is always the
  # smallest one this table can express.
  defp bump_decimal(text) do
    case String.split(text, ".") do
      [whole, frac] ->
        digits = String.length(frac)
        stepped = String.to_integer(whole <> frac) + 1
        padded = String.pad_leading(Integer.to_string(stepped), digits + 1, "0")
        {w, f} = String.split_at(padded, String.length(padded) - digits)
        w <> "." <> f

      [whole] ->
        Integer.to_string(String.to_integer(whole) + 1)
    end
  end

  # ONE ANCHORED EDIT. `global: false` so the mutant rewrites exactly the site
  # the anchor check counted.
  defp patch_file!(path, from, to) do
    source = File.read!(path)
    patched = String.replace(source, from, to, global: false)

    if patched == source do
      flunk("the mutation anchor #{inspect(from)} did not apply to #{path}.")
    end

    File.write!(path, patched)
  end

  defp population_perturbation(doc) do
    text = File.read!(doc)

    declared =
      case Regex.run(@pop_marker_re, text) do
        [_, n] ->
          String.to_integer(n)

        nil ->
          flunk(
            "could not read the `<!-- meter:population N -->` marker out of #{doc}. RE-POINT " <>
              "this derivation rather than pinning a count here."
          )
      end

    unless Regex.match?(@pop_prose_re, text) do
      flunk(
        "could not read METER.md §2's `on N/N** recorded duel envelopes` prose literal. Both " <>
          "places the population appears are perturbed together, so the mutant is a DRIFT " <>
          "against the corpus and not merely two markers disagreeing with each other."
      )
    end

    {declared, declared + 1}
  end

  defp patch_population!(doc) do
    patched =
      doc
      |> File.read!()
      |> then(
        &Regex.replace(@pop_marker_re, &1, fn _, n ->
          "<!-- meter:population #{String.to_integer(n) + 1} -->"
        end)
      )
      |> then(
        &Regex.replace(@pop_prose_re, &1, fn _, a, b ->
          "on #{String.to_integer(a) + 1}/#{String.to_integer(b) + 1}** recorded duel envelopes"
        end)
      )

    File.write!(doc, patched)
  end

  defp scale_envelope!(path, factor) do
    env = path |> File.read!() |> Jason.decode!()

    reported =
      Map.get(env, "total_cost_usd") ||
        flunk("#{path} carries no total_cost_usd -- this arm has nothing to perturb.")

    File.write!(path, Jason.encode!(Map.put(env, "total_cost_usd", reported * factor)))
  end

  # A WHOLE-TREE COPY, not a lone script: meter.py resolves its corpus and its
  # doc relative to ITS OWN directory, so a mutant written beside the original
  # would read the real METER.md and the real results/ and measure the wrong
  # thing. Each arm gets its own copy so the concurrent arms cannot collide.
  defp scratch_tree(dir, name, meter, doc, corpus) do
    into = Path.join(dir, name)
    File.mkdir_p!(into)

    for src <- [meter, doc, Path.join(Path.dirname(meter), "tally_wf.py")] do
      File.cp!(src, Path.join(into, Path.basename(src)))
    end

    File.cp_r!(corpus, Path.join(into, Path.basename(corpus)))

    %{
      root: into,
      meter: Path.join(into, Path.basename(meter)),
      doc: Path.join(into, Path.basename(doc)),
      corpus: Path.join(into, Path.basename(corpus))
    }
  end

  # rc is taken from System.cmd DIRECTLY. Never `cmd | tail`: under a shell that
  # is the PIPELINE's exit code, and a false green is exactly what this file is
  # here to stop.
  defp run_scratch(python, scratch) do
    System.cmd(python, [scratch.meter, "verify", scratch.corpus],
      cd: scratch.root,
      stderr_to_stdout: true
    )
  end

  defp assert_single_anchor(count, anchor) do
    assert count == 1,
           "the mutation anchor #{inspect(anchor)} occurs #{count}x in meter.py (expected " <>
             "exactly 1). At 0 this fail-demo proves nothing; above 1 the mutant rewrites a " <>
             "site nobody reasoned about."
  end

  defp occurrences(source, anchor), do: length(String.split(source, anchor)) - 1
end
