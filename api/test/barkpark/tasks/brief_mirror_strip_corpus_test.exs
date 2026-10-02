defmodule Barkpark.Tasks.BriefMirrorStripCorpusTest do
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.BriefMirror

  # THE CROSS-LANGUAGE HALF OF THE STRIP LOCK.
  #
  # One value — the markdown strip rule — lives on two surfaces. The Go
  # composer `ensureTaskPortableBrief` (internal/cli/tasks_create_cmd.go, via
  # `briefPurposeStripOnePass`) writes `purpose-copy` at create; this module
  # RE-DERIVES the same block on every subsequent write. Both sides being
  # tested is not a lock: two green suites with two hand-maintained expectation
  # tables is EXACTLY how this pair drifted, and the drift was invisible for as
  # long as it existed because each suite only ever asked its own side.
  #
  # So the lock is one file read by BOTH suites:
  # internal/cli/testdata/brief_strip_corpus.json — 1,313 mechanically
  # generated inputs (every tuple of length 1..4 over {*, **, _, __, `, a},
  # plus embedded/unterminated/runs/escaped/nested/unicode/crlf/code-span/link
  # families and the named shapes from the original finding), each row carrying
  # `input`, `one_pass` (the canonical expectation), `three_pass` (what this
  # module produced BEFORE the fix) and `divergent`. The Go half is
  # TestComposerMatchesSharedStripCorpus in
  # internal/cli/tasks_brief_strip_corpus_test.go. Editing EITHER
  # implementation now reds: the Go suite on its side, this file on ours.
  #
  # WHAT THIS FILE ADDS THAT THE GO HALF CANNOT. Nothing in Go can red when
  # brief_mirror.ex changes — `multiPassStrip` over there is a Go re-creation
  # of our old shape, a control, not a call into us. This file is the arm that
  # makes an edit to `strip_markdown/1` fail.
  #
  # MEASURED on Elixir over this corpus: the fixed one-pass form matches
  # `one_pass` on 1,313 of 1,313; the old reducing form matched `three_pass` on
  # 1,313 of 1,313 and `one_pass` on 1,294 — the 19 misses are the fixture's
  # `divergent` column, set-equal.
  #
  # THE ONE DIVERGING LIVE ROW, named here so a reader grepping the tree finds
  # it: task-8ba550b59141bccb, the row that reported the finding, whose own
  # description quotes the divergent shapes. Re-derived 2026-09-16 over 9,769
  # task documents carrying a string `description` (9,786 exported, 763 drafts,
  # 17 carrying no description key — not empty strings, of which there are
  # zero). Controls from the same run, so the 1 is a measurement and not a
  # predicate that never fired: 1,177 descriptions contain `**`, 884 contain
  # `__`, 3,948 contain a backtick, and the one-pass strip MODIFIED 4,582 of
  # them. A DENOMINATOR NOT TO INHERIT: PR #18522's body quotes "9,356 live
  # task descriptions"; that figure is verbatim the 2026-09-10 count in
  # tooling/grip/ledger/pds-tagregistry-twin-capture-2026-09-10.md and was not
  # produced by that run.

  @corpus_path Path.expand("../../../../internal/cli/testdata/brief_strip_corpus.json", __DIR__)
  @stub "Complete the work described by “strip parity” and record verifiable evidence."

  defp corpus do
    rows =
      @corpus_path
      |> File.read!()
      |> Jason.decode!()

    # An empty or truncated corpus passes every assertion below while measuring
    # nothing, so the floor is stated rather than assumed.
    assert length(rows) > 1_000,
           "#{@corpus_path} carries #{length(rows)} rows; the shared corpus is 1,313 " <>
             "mechanically generated inputs and a shrunken one measures less than it claims"

    rows
  end

  # An INDEPENDENT left-to-right non-overlapping scanner, written deliberately
  # NOT as :binary.replace/4 — the mirror of `referenceOnePass` in the Go half.
  # The corpus's `one_pass` column is re-derived from it below, so the fixture
  # is a statement ABOUT the rule rather than a transcript of the
  # implementation it guards. A guard whose expected value is read from the
  # thing it guards is inert.
  defp reference_one_pass(text), do: reference_one_pass(text, [])

  defp reference_one_pass("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp reference_one_pass(text, acc) do
    case Enum.find(["**", "__", "`"], &String.starts_with?(text, &1)) do
      nil ->
        <<byte::binary-size(1), rest::binary>> = text
        reference_one_pass(rest, [byte | acc])

      pattern ->
        reference_one_pass(
          binary_part(text, byte_size(pattern), byte_size(text) - byte_size(pattern)),
          acc
        )
    end
  end

  # The shape this module carried before the fix, reproduced here ONLY as a
  # control: it exists so the assertions below can be shown to SEE a
  # disagreement they were not written against. It is never an expectation.
  defp reference_three_pass(text),
    do: Enum.reduce(["**", "__", "`"], text, &String.replace(&2, &1, ""))

  defp composed_purpose(description) do
    attrs = %{
      "title" => "strip parity",
      "content" => %{
        "description" => description,
        "brief" => %{
          "version" => 1,
          "blocks" => [
            %{
              "id" => "purpose-copy",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "stale"}]
            }
          ]
        }
      }
    }

    attrs
    |> BriefMirror.maybe_resync_task_brief("task")
    |> get_in(["content", "brief", "blocks", Access.at(0), "content", Access.at(0), "value"])
  end

  test "the fixture's columns are re-derivable from an independent scanner" do
    for row <- corpus() do
      assert reference_one_pass(row["input"]) == row["one_pass"],
             "corpus row #{inspect(row["input"])}: one_pass is #{inspect(row["one_pass"])} " <>
               "but the independent scanner gives #{inspect(reference_one_pass(row["input"]))} " <>
               "— the fixture no longer states the one-pass rule"

      assert reference_three_pass(row["input"]) == row["three_pass"],
             "corpus row #{inspect(row["input"])}: three_pass is #{inspect(row["three_pass"])} " <>
               "but reducing over the patterns gives #{inspect(reference_three_pass(row["input"]))}"

      assert row["divergent"] == (row["one_pass"] != row["three_pass"]),
             "corpus row #{inspect(row["input"])}: divergent=#{inspect(row["divergent"])} " <>
               "but one_pass #{inspect(row["one_pass"])} vs three_pass " <>
               "#{inspect(row["three_pass"])} says otherwise"
    end
  end

  test "the mirror reproduces the composer's one-pass strip on every corpus row" do
    rows = corpus()

    mismatches =
      for row <- rows,
          want =
            if(String.trim(row["one_pass"]) == "", do: @stub, else: String.trim(row["one_pass"])),
          got = composed_purpose(row["input"]),
          got != want,
          do: {row["family"], row["input"], got, want}

    assert mismatches == [],
           "the mirror must strip markdown in ONE non-overlapping pass, as the composer " <>
             "does; #{length(mismatches)} of #{length(rows)} corpus rows disagree. First " <>
             "five: #{inspect(Enum.take(mismatches, 5), limit: :infinity)}"
  end

  # NON-VACUITY. A corpus that lost its divergent rows, or its agreeing ones,
  # still passes the assertion above while measuring nothing — and a run in
  # which the mirror was never reached would look identical to a clean one.
  test "the corpus carries both arms, so the assertion discriminates" do
    rows = corpus()
    divergent = Enum.count(rows, & &1["divergent"])
    agreeing = length(rows) - divergent

    assert divergent > 0,
           "the corpus carries no divergent row — `_**_` and `foo_**_bar` are the shapes " <>
             "this fixture exists for"

    assert agreeing > 0,
           "the corpus carries no agreeing row, so it cannot show the probe discriminates " <>
             "rather than reporting difference everywhere"

    assert divergent < agreeing,
           "#{divergent} of #{length(rows)} rows diverge: a corpus that disagrees more " <>
             "often than it agrees is describing a different rule, not this one"

    # THE CONTROL, stated as an assertion rather than a comment: on every
    # divergent row the OLD reducing form must still fail to reach the
    # expectation. If it reached it, this file would be blind to the very drift
    # it exists to catch.
    blind =
      for row <- rows,
          row["divergent"],
          reference_three_pass(row["input"]) == row["one_pass"],
          do: row["input"]

    assert blind == [],
           "control failed: the three-pass form now agrees with the composer on " <>
             "#{inspect(blind)}; this file can no longer see the drift it guards"

    # And the quiet arm: on every AGREEING row the old form reached the same
    # answer, so a harness that reported a disagreement everywhere would be
    # distinguishable from this one.
    noisy =
      for row <- rows,
          not row["divergent"],
          reference_three_pass(row["input"]) != row["one_pass"],
          do: row["input"]

    assert noisy == [],
           "control failed: #{inspect(Enum.take(noisy, 5))} are recorded as agreeing but " <>
             "the three-pass form disagrees with the composer on them"
  end

  test "the named shapes are present BY INPUT, not merely by count" do
    by_input = Map.new(corpus(), &{&1["input"], &1})

    for named <- ["_**_", "foo_**_bar", "a_**_b_**_c"] do
      row = by_input[named]

      assert row,
             "the corpus no longer carries #{inspect(named)}, a shape the finding was " <>
               "reported on"

      assert row["divergent"],
             "#{inspect(named)} is recorded as agreeing; it is a canonical divergent shape " <>
               "and a corpus that calls it agreeing has been edited to match the drift"
    end

    # The asymmetry is what names the mechanism as pass ORDER plus rescanning
    # rather than the patterns, so losing it leaves the diagnosis unsupported.
    mirror = by_input["*__*"]

    assert mirror && not mirror["divergent"],
           "the corpus must carry `*__*` as an AGREEING shape: its agreement, against " <>
             "`_**_`'s divergence, is what identifies the mechanism"
  end

  # THE WORST CLASS, and the one the original finding did not name: where the
  # description is ONLY the divergent shape, the old rescanning strip reduced it
  # to "" and fell through to the auto-stub, replacing the author's prose with
  # boilerplate. Not different prose — NO prose.
  test "the auto-stub escalation class is represented and is no longer reachable" do
    rows = corpus()

    stubbing =
      Enum.filter(rows, fn row ->
        String.trim(row["one_pass"]) != "" and String.trim(row["three_pass"]) == ""
      end)

    assert stubbing != [],
           "the corpus lost the AUTO-STUB escalation class — it is the worst consequence " <>
             "of the divergence and must stay represented"

    for row <- stubbing do
      assert composed_purpose(row["input"]) == String.trim(row["one_pass"]),
             "#{inspect(row["input"])} was erased into the auto-stub: the mirror replaced " <>
               "the author's description with boilerplate where the composer keeps " <>
               "#{inspect(String.trim(row["one_pass"]))}"
    end
  end

  # The pattern list's ORDER is inert under a single pass (the three patterns
  # begin with disjoint bytes, so leftmost-match never has to choose) and was
  # load-bearing under the old reducing form. Pinned in BOTH directions so a
  # later reader can tell which property they are relying on: a fixture that
  # pins only the value set would miss an arm reordered on one side alone.
  test "order is inert under one pass and load-bearing under the old form" do
    rows = corpus()
    reversed = fn text -> :binary.replace(text, ["`", "__", "**"], "", [:global]) end

    reversed_three = fn text ->
      Enum.reduce(["`", "__", "**"], text, &String.replace(&2, &1, ""))
    end

    order_sensitive_one_pass =
      for row <- rows, reversed.(row["input"]) != row["one_pass"], do: row["input"]

    assert order_sensitive_one_pass == [],
           "reversing the pattern list changed #{length(order_sensitive_one_pass)} one-pass " <>
             "outputs; under a single non-overlapping pass over disjoint-prefix patterns " <>
             "order must be inert"

    order_sensitive_three_pass =
      for row <- rows, reversed_three.(row["input"]) != row["three_pass"], do: row["input"]

    assert order_sensitive_three_pass != [],
           "reversing the pattern list changed NO three-pass output — the old form's " <>
             "order-sensitivity is half the diagnosis and this control has stopped firing"
  end
end
