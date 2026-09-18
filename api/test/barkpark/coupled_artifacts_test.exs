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
      reporting a clean one,
    * PREDICATE 2 (task-c5b0e402137a2d4f) stops seeing a committed pin that a
      workflow-invoked script compares against and offers to re-pin,
    * the pin parser goes UNIFORM — classifying every script the same way,
      which is the signature of a broken instrument rather than a rule.

  THE TWO ARMS RED ON DIFFERENT MUTATIONS, which is the point of having two:
  neutering `@diff_re` reds only the regenerate-then-diff arm; neutering
  `@repin_vocab` reds only the pin-comparison arm. Both were run; see the PR.
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

  # ── PREDICATE 2: the pin comparison (task-c5b0e402137a2d4f) ───────────────

  defp pins, do: Enum.filter(couplings(), &(&1.kind == :pin_comparison))

  defp bindings_pin do
    Enum.find(pins(), &("api/.sobelow-annotation-bindings" in &1.artifacts))
  end

  describe "PREDICATE 2 sees the pin coupling predicate 1 is blind to" do
    test "api/.sobelow-annotation-bindings is derived, with its regen affordance named" do
      c = bindings_pin()

      refute is_nil(c),
             """
             api/.sobelow-annotation-bindings is no longer derived as a coupled
             artifact. It is guarded by api/scripts/sobelow-inline-overlap-check.sh,
             which a step in .github/workflows/security.yml runs, and cured by
             --regen-bindings-pin. Either that script changed shape (it no longer
             reads the pin, no longer writes it, or no longer prints the cure beside
             $0) or the pin predicate stopped matching it.
             derived pins: #{inspect(Enum.flat_map(pins(), & &1.artifacts))}
             """

      assert c.producer == [
               "bash api/scripts/sobelow-inline-overlap-check.sh --regen-bindings-pin"
             ],
             "the AFFORDANCE must be the producer, not the guard. got: #{inspect(c.producer)}"

      assert c.guard == ["bash api/scripts/sobelow-inline-overlap-check.sh"],
             """
             The guard must be the BARE invocation — the command the gate runs.
             A guard carrying --selftest judges a fixture tree, not this one.
             got: #{inspect(c.guard)}
             """

      assert c.workflow == ".github/workflows/security.yml"
      assert c.job == "sobelow-inline-overlap"
    end

    test "predicate 1 alone cannot see it — the blindness this row was filed about" do
      # The point is not that the pin is derived; it is that it is derived by the
      # SECOND rule. If it ever appears under :regenerate_then_diff, the shapes
      # have merged and this arm is measuring nothing.
      regen = Enum.filter(couplings(), &(&1.kind == :regenerate_then_diff))

      refute Enum.any?(regen, &("api/.sobelow-annotation-bindings" in &1.artifacts)),
             "the pin is now attributed to regenerate-then-diff: #{inspect(regen)}"

      assert bindings_pin().kind == :pin_comparison
    end

    test "predicate 2 is a rule, not a one-artifact special case" do
      assert length(pins()) >= 2,
             "derived only #{length(pins())} pin coupling(s): " <>
               "#{inspect(Enum.flat_map(pins(), & &1.artifacts))}. A rule that fits " <>
               "exactly its worked example has probably been narrowed onto it."

      for c <- pins() do
        assert [affordance] = c.producer

        assert affordance =~ ~r/--(re-?gen|re-?pin|update)/,
               "pin producer #{inspect(affordance)} is not an affordance invocation"
      end
    end
  end

  describe "MUTATION ARM: the pin parser is NON-UNIFORM" do
    # A uniform verdict is the signature of a broken instrument. These arms
    # assert the parser SEPARATES scripts, and separates files WITHIN one script.

    @workflow_scripts [
      "api/scripts/sobelow-inline-overlap-check.sh",
      "api/scripts/sobelow-baseline-staleness-check.sh",
      "api/scripts/sobelow-baseline-fingerprint-check.sh",
      "api/scripts/sobelow-waiver-merge-time-check.sh",
      "api/scripts/prod-postcheck.sh"
    ]

    test "it declares pins for some workflow-invoked scripts and NOT for others" do
      declaring =
        Enum.filter(@workflow_scripts, fn s ->
          CoupledArtifacts.pin_declarations(@repo_root, s) != []
        end)

      # Control: the population is real. An absence is never caught by
      # inspection — print the key set before treating an empty read as evidence.
      for s <- @workflow_scripts do
        assert File.regular?(Path.join(@repo_root, s)),
               "probe is broken, not the parser: #{s} is not in the checkout"
      end

      assert declaring != [], "the parser declared NOTHING — it is not running"

      assert length(declaring) < length(@workflow_scripts),
             """
             The parser declared a pin for EVERY script it was shown. A uniform
             verdict is the signature of a broken instrument, not of a tree where
             everything is pinned. declaring: #{inspect(declaring)}
             """

      assert "api/scripts/sobelow-inline-overlap-check.sh" in declaring

      refute "api/scripts/sobelow-baseline-fingerprint-check.sh" in declaring,
             "fingerprint-check has no re-pin affordance at all; declaring a pin " <>
               "for it means conjunct 3 stopped discriminating"
    end

    test "WITHIN one script it separates the pin from the file it merely reads" do
      decls =
        CoupledArtifacts.pin_declarations(
          @repo_root,
          "api/scripts/sobelow-inline-overlap-check.sh"
        )

      artifacts = Enum.map(decls, & &1.artifact)

      assert "api/.sobelow-annotation-bindings" in artifacts

      # Control: the script really does resolve .sobelow-skips to a committed
      # file — so its ABSENCE below is discrimination, not a failure to parse.
      assert File.regular?(Path.join(@repo_root, "api/.sobelow-skips"))

      assert File.read!(Path.join(@repo_root, "api/scripts/sobelow-inline-overlap-check.sh")) =~
               "BASELINE=\"$API_DIR/.sobelow-skips\""

      refute "api/.sobelow-skips" in artifacts,
             """
             api/.sobelow-skips was swept in. The same script resolves it to a
             committed file and READS it — but nothing in that script WRITES it and
             nothing prints a re-pin cure for it, so conjuncts 2 and 3 are false.
             Sweeping it in means the predicate degenerated to "a committed file a
             script reads", which is most of the repo. declared: #{inspect(artifacts)}
             """
    end

    test "a script no workflow step names contributes nothing, however shaped" do
      # The descent is workflow-driven. A script with the right shape that no
      # gate runs is not a coupling — nothing reds if it drifts.
      derived = Enum.flat_map(pins(), & &1.artifacts)

      refute "api/scripts/sobelow-annotation-transfer-check.sh" in derived

      assert Enum.all?(pins(), fn c ->
               [g] = c.guard
               String.contains?(g, ".sh")
             end)
    end
  end

  describe "PREDICATE 2 goes QUIET on a clean tree" do
    test "the real guard exits 0 on this checkout, so the pin arm reports nothing" do
      c = bindings_pin()
      [cmd] = c.guard
      [exe | args] = String.split(cmd, ~r/\s+/, trim: true)

      {out, status} =
        System.cmd(exe, args, cd: @repo_root, stderr_to_stdout: true)

      assert status == 0,
             """
             The pin guard reds on a tree with no pending change, which means either
             the pin is genuinely stale (re-pin it, in THIS commit, with
             #{Enum.join(c.producer, " ")} — then READ THE DIFF) or the guard is
             measuring something else. Guard output:
             #{out}
             """

      # The decision function, given that live result, must be silent.
      assert [] == CoupledArtifacts.violations([c], fn _ -> [] end)
    end

    test "and reds — naming the artifact — the moment the guard would fail" do
      c = bindings_pin()

      assert [{^c, ["api/.sobelow-annotation-bindings"]}] =
               CoupledArtifacts.violations([c], fn x -> x.artifacts end)
    end
  end
end
