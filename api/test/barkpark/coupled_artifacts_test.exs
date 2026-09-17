defmodule Barkpark.CoupledArtifactsTest do
  @moduledoc """
  THE NAMED TRIGGER for task-0f8776aa215d2d4e.

  A written finding does not fire by itself. `Barkpark.CoupledArtifacts` states
  the rule; this file is what REDS when the rule stops holding. It runs in
  `mix test`, which runs inside the `Elixir gate` — the required context — so a
  PR that breaks the derivation cannot merge on the strength of the prose alone.

  Each test names the specific way the coupling declaration can go wrong:

    * the derivation stops seeing the openapi coupling at all (vacuous green),
    * the derivation stops attributing it to a REQUIRED gate (advisory drift),
    * the rule degenerates into the naive same-string rule and sweeps in
      `docs/cli/fixtures/full-manifest.json`, which has NO producer and which
      doctrine forbids both hand-editing and regenerating,
    * `--check`'s decision function stops reporting a dirty artifact, or starts
      reporting a clean one.
  """
  use ExUnit.Case, async: true

  alias Barkpark.CoupledArtifacts

  @repo_root Path.expand("../../..", __DIR__)

  # The sentence PR #18415 edited in api/lib/barkpark/plugins/tasks.ex. It is
  # embedded in BOTH docs/openapi.json (gated) and
  # docs/cli/fixtures/full-manifest.json (gated by nothing). Kept here only to
  # drive the mutation arm — never to decide anything.
  @shared_sentence "acceptance criterion"

  defp couplings, do: CoupledArtifacts.derive(@repo_root)

  defp openapi_coupling do
    Enum.find(couplings(), &("docs/openapi.json" in &1.artifacts))
  end

  describe "the derivation sees the coupling this row was filed about" do
    test "docs/openapi.json is derived, with its producer and its REQUIRED gate" do
      c = openapi_coupling()

      refute is_nil(c),
             """
             docs/openapi.json is no longer derived as a coupled generated artifact.
             Either the drift step in .github/workflows/elixir.yml changed shape, or
             the predicate in Barkpark.CoupledArtifacts stopped matching it. Run
             `mix barkpark.coupled` and compare against the step named
             "OpenAPI drift check" in that workflow.
             """

      assert "mix barkpark.openapi" in c.producer,
             "the producer must be NAMED, not implied. got: #{inspect(c.producer)}"

      assert c.producer_dir == "api"
      assert c.workflow == ".github/workflows/elixir.yml"

      assert c.required?,
             """
             The openapi drift check is no longer attributed to a REQUIRED context.
             A coupling behind an advisory check costs a lane a round trip; one
             behind a required check blocks the merge. gates seen: #{inspect(c.gates)}
             required contexts: #{inspect(CoupledArtifacts.required_contexts(@repo_root))}
             """

      assert "Elixir gate" in c.gates
    end

    test "every derived coupling names a producer — an unnamed producer is not actionable" do
      for c <- couplings() do
        assert c.producer != [],
               "coupling at #{c.workflow}:#{c.line} (#{c.step}) derived artifacts " <>
                 "#{inspect(c.artifacts)} with NO producer. A lane told 'this must move' " <>
                 "and not told what writes it will hand-edit it, which is the defect."
      end
    end

    test "the derivation is not empty and is not a one-artifact special case" do
      # An enumeration is a snapshot; a predicate is a rule. If this ever drops
      # to exactly the openapi row, the predicate has probably been narrowed to
      # fit its worked example.
      cs = couplings()
      assert length(cs) >= 2, "derived only #{length(cs)} coupling(s): #{inspect(cs)}"

      artifacts = Enum.flat_map(cs, & &1.artifacts)
      assert Enum.any?(artifacts, &String.starts_with?(&1, "docs/"))
      assert Enum.any?(artifacts, &(not String.starts_with?(&1, "docs/")))
    end
  end

  describe "MUTATION ARM: the sibling that shares the string but not the gate" do
    test "a naive same-string rule sweeps in the ungated fixture; the gate rule does not" do
      naive = CoupledArtifacts.naive_same_string_rule(@repo_root, @shared_sentence)

      # Control first: if the naive rule found neither file, this test would pass
      # vacuously while measuring nothing. An absence is never caught by
      # inspection — assert the population exists before asserting a difference.
      assert "docs/openapi.json" in naive,
             "the naive rule did not even find docs/openapi.json — the probe is broken, " <>
               "not the rule. naive returned: #{inspect(naive)}"

      assert "docs/cli/fixtures/full-manifest.json" in naive,
             """
             The naive same-string rule no longer sweeps in the ungated fixture, so this
             arm no longer measures the thing it exists to measure. Either the fixture
             stopped carrying the shared sentence (pick a new @shared_sentence that both
             files carry) or the fixture is gone. Do NOT delete this arm: it is the only
             place that proves the chosen rule discriminates by GATE rather than by grep.
             naive returned: #{inspect(naive)}
             """

      derived = couplings() |> Enum.flat_map(& &1.artifacts)

      assert "docs/openapi.json" in derived

      refute "docs/cli/fixtures/full-manifest.json" in derived,
             """
             The gate-derived rule swept in docs/cli/fixtures/full-manifest.json.
             That file has NO producer anywhere in the tree and its only workflow
             mention is an `on: paths:` trigger COMMENT in go-tests.yml — doctrine
             forbids both hand-editing it and regenerating it. A lane told to
             "regenerate it for consistency" writes a file no gate asked to move.
             derived: #{inspect(derived)}
             """
    end

    test "the fixture really has no producer: no workflow step regenerates and diffs it" do
      # The reason the fixture is excluded, asserted directly rather than
      # inferred from the rule's own output — otherwise the rule is its own
      # witness.
      for c <- couplings() do
        refute Enum.any?(c.artifacts, &String.contains?(&1, "full-manifest.json")),
               "a producer appeared for full-manifest.json at #{c.workflow}:#{c.line}. " <>
                 "If someone genuinely added one, this row's premise changed: re-read " <>
                 "the charter lines that forbid regenerating it before trusting the gate."
      end
    end
  end

  describe "the check reds when the coupling is violated, and only then" do
    setup do
      c = openapi_coupling()
      %{coupling: c}
    end

    test "a dirty artifact after regeneration is a violation naming the artifact", %{
      coupling: c
    } do
      # The dirtiness probe is injected, so this arm tests the DECISION, not the
      # 40-second producer run. The producer run itself is exercised for real by
      # `mix barkpark.coupled --check`.
      dirty_fun = fn ^c -> ["docs/openapi.json"] end

      assert [{^c, ["docs/openapi.json"]}] = CoupledArtifacts.violations([c], dirty_fun)
    end

    test "a clean tree is silent — the check does not red on a legitimate commit", %{
      coupling: c
    } do
      assert [] == CoupledArtifacts.violations([c], fn _ -> [] end)
    end

    test "a violation is reported per coupling, not collapsed into one", %{coupling: c} do
      other = %{c | artifacts: ["web/__tests__/fixtures/x.golden.json"], step: "other"}

      assert [{_, _}, {_, _}] =
               CoupledArtifacts.violations([c, other], fn x -> x.artifacts end)
    end
  end
end
