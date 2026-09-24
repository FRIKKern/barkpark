defmodule BarkparkWeb.FinderCorpusQueryCostTest do
  @moduledoc """
  THE COST OF `/finder`'s CORPUS FOLD, COUNTED — not estimated.

  `dr-w8-s3` removed ~1,300 serial DB round-trips from the flat `/v1/graph`
  corpus derivation by threading `dangling: :skip` (and a `:schemas` prefetch)
  into `extract_edges/2`. `FinderLive.graph_payload/3` is the SECOND consumer
  of the same corpus shape — a Studio-adjacent LiveView on the PUBLIC `/finder`
  route — and it folded `Content.corpus_edges/3` over every type through the
  unchanged `:resolve` default, so on every connected mount it still paid:

    * one un-batched existence query per reference VALUE per document, for a
      `dangling` boolean this path never reads (the edge projection keeps only
      from_id/to_id/kind; phantoms are decided IN MEMORY off `node_ids`);
    * one schema-list query per DOCUMENT (no `:schemas` prefetch);
    * a second full document scan per TYPE (`corpus_edges/3` re-reads the very
      documents `graph_payload/3` already holds in `doc_lists`).

  ## Why the assertion is DIFFERENTIAL, not an absolute number

  A fixed structural cost (schemas list, one document list per type, the
  workspace lookup, the LiveView's own reads) is not what this row is about and
  is not stable across unrelated changes. What IS the defect is that the count
  GREW WITH THE CORPUS. So the measurement mounts the same page twice over the
  same schema — once at `@small` documents, once at `@small + @grow` — and
  asserts the SECOND mount costs no more queries than the first.

  MEASURED, on the fixture below (6 -> 12 documents, two reference values each):

    | code                                   | 6 docs | 12 docs | delta |
    |----------------------------------------|--------|---------|-------|
    | origin/main (`corpus_edges/3`)         |     37 |      61 |   +24 |
    | this fix                               |      7 |       7 |     0 |
    | mutation: `dangling: :skip` removed    |     31 |      55 |   +24 |

  The growth term is exactly the dangling resolution: 12 added reference values
  x the two queries `resolve_target_existence/4` spends per TYPED target (it
  calls `Content.get_document/4`). The 37 -> 31 drop in the mutation column is
  the `:schemas` prefetch and the removed second document scan — real, but
  CONSTANT in the corpus size, which is why the assertion is the delta.

  COUNTING METHOD: `Barkpark.QueryCounter` (test/support/query_counter.ex), the
  shared LINEAGE-SCOPED census over the Ecto telemetry event
  `[:barkpark, :repo, :query]`. Query COUNT (not wall clock) is the measure on
  purpose — this machine runs many agents and milliseconds are noise.

  ## The counter has a SUBJECT, not an ambient

  This module used to attach its OWN handler and count the event from ANY
  process in the VM. That is what made it a flaky REQUIRED gate: it reddened a
  comment-only CSS diff on studio PR #19949 with `delta -> 1 (expected <= 0)`,
  and a rebase carrying no change to this file turned it green.

  `async: false` is kept, but it is NOT what makes the count safe, and an
  earlier version of this note claimed it was. `async: false` fences sibling
  ExUnit CASES. It fences nothing in the running OTP application — a
  `StudioChat.BlockedSweeper` tick, an Oban plugin tick, a lingering
  `start_async` Task from an EARLIER test's LiveView all keep issuing
  statements inside the measured window, and each was +1 against a ZERO-slack
  assertion guarding a +24 signal. The exposure is asymmetric toward false
  positives, because the second window mounts twice the corpus and is strictly
  longer than the first.

  `QueryCounter` resolves OWNERSHIP instead: a statement counts only when its
  issuing process is this test process, a pid named with `own/1` (the LiveView
  serving the connected mount, see `mount_corpus/1`), or a process spawned by
  either — `$callers` / `$ancestors`. A process the application supervisor
  started at boot satisfies none of those and is excluded BY CONSTRUCTION. That
  exclusion has its own permanent leak trap in `Barkpark.QueryCounterTest`:
  a lineage-less `spawn/1` issues a real statement inside a measured window and
  the census must not move, while a LiveView mount in the same window must be
  counted.

  A self()-ONLY filter would instead make THIS module vacuous, because
  `graph_payload/3` runs inside the LiveView's `start_async` Task. Measured on
  the fixture below, the 7 small-corpus statements split 1 (the test process) /
  1 (the LiveView, `$callers` = [test]) / 5 (the async Task, `$callers` =
  [view, test]) — the same 7 the old whole-application handler saw. The
  measurement asserts that the count raised OUTSIDE the test process is
  non-zero for exactly that reason: if ownership ever stops reaching the Task,
  the count collapses toward zero, the delta assertion passes trivially, and
  that control fails first and loudly instead.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.QueryCounter

  @dataset "findercost"
  @type_name "findercostptr"
  @target_type "findercosttgt"

  # 6 + 6 documents: every added document carries TWO reference values, so the
  # old code's growth term is 2 * @grow existence queries + @grow schema reads.
  @small 6
  @grow 6

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @target_type,
          "title" => @target_type,
          "visibility" => "public",
          "fields" => []
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => @type_name,
          "visibility" => "public",
          "fields" => [
            # `rel` resolves to a real document, `alt` dangles. Two reference
            # values per document — both cost one existence round-trip each
            # under the `:resolve` default.
            %{"name" => "rel", "type" => "reference", "refType" => @target_type},
            %{"name" => "alt", "type" => "reference", "refType" => @target_type}
          ]
        },
        @dataset,
        scope
      )

    publish!(@target_type, "fc-target", %{}, scope)

    %{scope: scope}
  end

  defp publish!(type, doc_id, content, scope) do
    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, type, @dataset, scope)
    doc
  end

  defp seed_pointers!(scope, from, count) do
    for i <- from..(from + count - 1) do
      publish!(
        @type_name,
        "fc-ptr-#{i}",
        %{"rel" => "fc-target", "alt" => "fc-missing-#{i}"},
        scope
      )
    end
  end

  # Count the statements OWNED by this measurement while `fun` runs — the test
  # process, the LiveView `mount_corpus/1` names with `QueryCounter.own/1`, and
  # anything either of them spawned. Cross-process on purpose (the corpus
  # derivation runs in the LiveView's `start_async` Task); application-wide
  # never again (see the "SUBJECT, not an ambient" note above).
  #
  # Returns `%{total: n, outside_test_process: n}`. The second figure is the
  # anti-vacuity control: it is the part of the count that proves the Task's own
  # statements are still being seen.
  defp count_queries(fun) do
    test_pid = self()
    {result, events} = QueryCounter.capture(fun)

    {result,
     %{
       total: length(events),
       outside_test_process: Enum.count(events, &(&1.pid != test_pid))
     }}
  end

  defp mount_corpus(conn) do
    {:ok, view, _html} = live(conn, "/finder?dataset=#{@dataset}")

    # The connected mount runs IN the LiveView process, which is where the
    # corpus fold's `start_async` Task is spawned from. Naming it here is what
    # keeps the measurement's subject whole.
    QueryCounter.own(view.pid)

    render_async(view, 10_000)
  end

  describe "the /finder corpus fold" do
    test "costs no MORE queries when the corpus grows — the per-document round trips are gone",
         %{conn: conn, scope: scope} do
      seed_pointers!(scope, 1, @small)

      # CONTROL, the permit direction first: the corpus actually landed, so the
      # counts below are read off a real derivation and not off an empty page.
      {html_small, small} = count_queries(fn -> mount_corpus(conn) end)

      assert html_small =~ "fc-ptr-1",
             "the corpus payload is empty — the query counts measure nothing"

      assert html_small =~ "fc-missing-1",
             "phantom (dangling-target) nodes are missing — the edge fold did not run"

      # ANTI-VACUITY CONTROL, and the one that guards the ownership scoping:
      # the corpus fold runs in the LiveView's `start_async` Task, so MOST of
      # this count must come from outside the test process. Narrow ownership
      # too far and this reads 0 — at which point the delta assertion below
      # would be passing on a counter that sees nothing.
      assert small.outside_test_process > 0,
             """
             the census owns NO statement outside the test process, so the
             LiveView's `start_async` corpus fold is not being counted at all —
             the delta assertion below would be vacuous:
               total -> #{small.total}
             """

      seed_pointers!(scope, @small + 1, @grow)

      {html_grown, grown} = count_queries(fn -> mount_corpus(conn) end)

      # CONTROL: the second mount really did derive the LARGER corpus.
      assert html_grown =~ "fc-ptr-#{@small + @grow}",
             "the grown corpus is missing its new documents — the delta measures nothing"

      assert grown.outside_test_process > 0,
             "the grown mount owns no out-of-test-process statement — see above"

      small_queries = small.total
      grown_queries = grown.total

      # THE MEASUREMENT. Every per-document DB round-trip is gone, so adding
      # @grow documents (2 * @grow reference values) adds ZERO queries.
      # BEFORE this fix the delta was 2 * @grow existence queries plus @grow
      # per-document schema reads.
      assert grown_queries <= small_queries,
             """
             the corpus fold still pays per-document DB round-trips:
               #{@small} docs  -> #{small_queries} queries
               #{@small + @grow} docs -> #{grown_queries} queries
               delta           -> #{grown_queries - small_queries} (expected <= 0)
             """
    end

    test "MUTATION GUARD: the `:resolve` default is untouched — /v1/graph/dangling and EdgeProjector still resolve",
         %{scope: scope} do
      [doc | _] = seed_pointers!(scope, 100, 1)

      # No `:dangling` opt at all — the EdgeProjector / `Graph.dangling/1` /
      # `corpus_edges/3` call shape. If the finder's `dangling: :skip` ever
      # migrates from its local `edge_opts` into the default, every edge here
      # goes `nil` and the dangling report (which filters on `& &1.dangling`,
      # where nil is falsy) silently empties.
      edges = Content.extract_edges(doc)

      assert Enum.find(edges, &(&1.field == "rel")).dangling == false
      assert Enum.find(edges, &(&1.field == "alt")).dangling == true
    end
  end
end
