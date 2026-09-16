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

  COUNTING METHOD: the Ecto telemetry event `[:barkpark, :repo, :query]` — the
  same instrument `Barkpark.Content.EdgesTest` uses for the `/v1/graph` half of
  this defect. It is attached for the duration of one mount and counts events
  from ANY process, because `graph_payload/3` runs in a `start_async` Task and
  a self()-filtered handler would count zero of the queries under test. That is
  why this module is `async: false`: sync tests run alone, so no concurrent
  ExUnit case can inflate the count. Query COUNT (not wall clock) is the
  measure on purpose — this machine runs many agents and milliseconds are noise.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

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

  # Count [:barkpark, :repo, :query] emissions raised by ANY process while
  # `fun` runs. Cross-process on purpose: the corpus derivation runs inside the
  # LiveView's `start_async` Task, not in the test process.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = {:finder_cost_counter, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, _meta, _config -> send(test_pid, :repo_query) end,
      nil
    )

    try do
      result = fun.()
      {result, drain(0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(n) do
    receive do
      :repo_query -> drain(n + 1)
    after
      0 -> n
    end
  end

  defp mount_corpus(conn) do
    {:ok, view, _html} = live(conn, "/finder?dataset=#{@dataset}")
    render_async(view, 10_000)
  end

  describe "the /finder corpus fold" do
    test "costs no MORE queries when the corpus grows — the per-document round trips are gone",
         %{conn: conn, scope: scope} do
      seed_pointers!(scope, 1, @small)

      # CONTROL, the permit direction first: the corpus actually landed, so the
      # counts below are read off a real derivation and not off an empty page.
      {html_small, small_queries} = count_queries(fn -> mount_corpus(conn) end)

      assert html_small =~ "fc-ptr-1",
             "the corpus payload is empty — the query counts measure nothing"

      assert html_small =~ "fc-missing-1",
             "phantom (dangling-target) nodes are missing — the edge fold did not run"

      seed_pointers!(scope, @small + 1, @grow)

      {html_grown, grown_queries} = count_queries(fn -> mount_corpus(conn) end)

      # CONTROL: the second mount really did derive the LARGER corpus.
      assert html_grown =~ "fc-ptr-#{@small + @grow}",
             "the grown corpus is missing its new documents — the delta measures nothing"

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
