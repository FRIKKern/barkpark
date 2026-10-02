defmodule BarkparkCloud.CancelledProducerCensusTest do
  @moduledoc """
  THE CANCELLED-ROW PRODUCER CENSUS (`dr-w16-bl-cancelled-rows-rationale-is-wrong`).

  A `cancelled` deployment row is NOT a deploy a human stopped. There is no
  human cancel path in `cloud/lib` and the console ships no such affordance;
  every producer is machine-driven. That fact is load-bearing — it is the whole
  reason the delivery census and `SitePublishWaitingAlert` must keep cancelled
  rows out of the still-waiting cohort, and the reason the objection is "do not
  report a publish the FLEET refused as content still on its way", not "do not
  accuse a user of their own action".

  Two arms, both derived from SOURCE TEXT at run time:

    * **ARM A — the producer set.** The comment-stripped set of files under
      `cloud/lib` that WRITE `status: "cancelled"` onto a deployment must be
      exactly the two known automatic producers. A third literal writer must
      come with a prose update, so this reds until the census is taught about
      it. (The fenced builder/agent transition routes are a THIRD way a row
      reaches `cancelled` — a build box POSTing `status` — but they pass the
      value through from the request body, so no literal appears there. They
      are named in prose in `DeployLedger.delivery/3`'s moduledoc instead.)

    * **ARM B — the retired premise.** No file under `cloud/lib` OR
      `cloud/test` may re-assert the human-cancel framing. Each banned phrase is
      the literal wording a correction removed; re-introducing any of them reds
      this test. The test tree is in scope because that is where the premise
      survived: after #18528 cleaned `cloud/lib`, seven test comments, one test
      name and three fixture `failure_reason` strings still narrated a person
      stopping the deploy (and one `cloud/lib` comment the phrase list missed) (charter D614(c): three producers, none a person;
      D621). This file is the one exclusion — it must spell the banned phrases
      to ban them. A test that BUILDS a cancelled row is not a hit: the list is
      narrative phrases, never the status word.

  Fail-closed: an empty ARM A scan is a NAMED raise, never a pass. An empty
  producer set reads as "no unknown producers" and would be a vacuous green.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../lib/barkpark_cloud", __DIR__)
  @test_root Path.expand("..", __DIR__)
  @self Path.expand(__ENV__.file)

  # The literal write of a cancelled DEPLOYMENT status. `status ==` comparisons
  # and `~w(... cancelled)` membership lists are readers, not producers, and do
  # not match. A line carrying a backtick is PROSE quoting the write (the
  # moduledoc enumeration one module away) and is excluded — Elixir code never
  # carries a backtick outside a doc string or a comment.
  @producer_re ~r/^[^`]*status:\s*"cancelled"/m

  # Both known automatic producers, as repo-relative paths:
  #   registry.ex             — cancel_preview/2 (preview supersede + branch teardown)
  #   sites/auto_deploy_worker.ex — refuse/1 (the prebuilt-overwrite guard)
  @known_producers ~w(registry.ex sites/auto_deploy_worker.ex)

  # The retired premise, phrase by phrase. Case-insensitive.
  @banned [
    ~r/a deploy a human deliberately stopped/i,
    ~r/a deploy a human stopped/i,
    ~r/rows a human cancelled/i,
    ~r/human-cancelled/i,
    ~r/the team itself cancelled/i,
    ~r/a deploy the team itself stopped/i,
    ~r/a build a person stopped/i,
    # The test-tree wording (task-cf045b0525aafb81), each removed by the same PR
    # that put cloud/test in scope.
    ~r/rows? a human stopped/i,
    ~r/stopped by hand/i,
    ~r/a person stopped this/i,
    ~r/by a human's decision/i,
    ~r/a row a human cancel/i,
    ~r/operator cancelled the deploy/i,
    ~r/an operator's cancel/i,
    ~r/cancelled by operator/i
  ]

  defp ex_sources do
    files = Path.wildcard(Path.join(@lib_root, "**/*.ex"))

    if files == [] do
      raise "CancelledProducerCensus: no .ex sources under #{@lib_root}. " <>
              "The tree moved — re-point @lib_root. Refusing to measure nothing."
    end

    for f <- files, do: {Path.relative_to(f, @lib_root), File.read!(f)}
  end

  # Every .ex/.exs under `root` except this file, as {path, source}. Takes the
  # root as an argument so the planted-file control below drives the SAME code.
  defp test_sources(root) do
    files =
      Path.wildcard(Path.join(root, "**/*.{ex,exs}"))
      |> Enum.reject(&(Path.expand(&1) == @self))

    if files == [] do
      raise "CancelledProducerCensus: no .ex/.exs sources under #{root}. " <>
              "The tree moved — re-point @test_root. Refusing to measure nothing."
    end

    for f <- files, do: {"test/" <> Path.relative_to(f, root), File.read!(f)}
  end

  defp premise_hits(sources) do
    for {rel, src} <- sources,
        re <- @banned,
        Regex.match?(re, src),
        do: "#{rel}: #{inspect(re.source)}"
  end

  # Full-line Elixir comments blanked. A phrase that survives is either code or
  # a doc string (`@moduledoc`/`@doc`), and both are claims this census governs;
  # `#` comment lines are stripped here and scanned separately in ARM B, which
  # reads the RAW source on purpose — a false premise in a comment is exactly
  # what this correction removed.
  defp strip_comments(src) do
    src
    |> String.split("\n")
    |> Enum.map(fn line ->
      if Regex.match?(~r/^\s*#(?!\{)/, line), do: "", else: line
    end)
    |> Enum.join("\n")
  end

  test "ARM A: every literal cancelled-status writer under cloud/lib is a known automatic producer" do
    found =
      for {rel, src} <- ex_sources(),
          Regex.match?(@producer_re, strip_comments(src)),
          do: rel

    assert found != [],
           "CancelledProducerCensus ARM A found ZERO cancelled-status writers under " <>
             "#{@lib_root}. The producers cannot have vanished — the scan is broken. " <>
             "Refusing to report a vacuous green."

    assert Enum.sort(found) == Enum.sort(@known_producers),
           """
           The set of files that WRITE `status: "cancelled"` onto a deployment changed.

             expected: #{inspect(Enum.sort(@known_producers))}
             found:    #{inspect(Enum.sort(found))}

           A new producer is not forbidden — but `DeployLedger.delivery/3`'s
           moduledoc enumerates the producers to a human reader, and it is now
           out of date. Teach BOTH, or this census is lying about the population
           (dr-w16-bl-cancelled-rows-rationale-is-wrong).
           """
  end

  test "ARM B: no file under cloud/lib or cloud/test re-asserts the retired human-cancel premise" do
    test_files = test_sources(@test_root)

    # Precondition: the test scan saw the tree it claims to govern — .exs files,
    # including the deploy-ledger suite where the premise last lived — and
    # excluded exactly this file.
    rels = Enum.map(test_files, &elem(&1, 0))
    assert "test/barkpark_cloud/deploy_ledger_test.exs" in rels
    refute Enum.any?(rels, &String.ends_with?(&1, "cancelled_producer_census_test.exs"))

    hits = premise_hits(ex_sources() ++ test_files)

    assert hits == [],
           """
           A `cancelled` deployment row is not a deploy a person stopped: no human
           cancel path exists in cloud/lib (dr-w16-bl-cancelled-rows-rationale-is-wrong;
           charter D614(c), D621). Test prose is held to the same fact.
           These sources re-assert the retired premise:

           #{Enum.join(hits, "\n")}

           The true framing: the fleet refused the publish (an auto-deploy
           prebuilt-overwrite refusal, a preview supersede or teardown, or a
           build box filing the terminal on the fenced transition route).
           """
  end

  # CONTROL for ARM B's test-tree arm: a phrase planted in a .exs file under a
  # scratch root must be found by the same scanner, so an ARM B green over
  # cloud/test is a measurement and not a scan that never reads test files.
  @tag :tmp_dir
  test "ARM B control: a planted premise phrase in a test file is a hit", %{tmp_dir: dir} do
    planted = Path.join([dir, "barkpark_cloud", "planted_test.exs"])
    File.mkdir_p!(Path.dirname(planted))
    File.write!(planted, "  # This row is a deploy a human stopped.\n")
    File.write!(Path.join(dir, "clean_test.exs"), "  # a fleet-cancelled row\n")

    assert premise_hits(test_sources(dir)) ==
             [~s(test/barkpark_cloud/planted_test.exs: "a deploy a human stopped")]
  end
end
