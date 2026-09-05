defmodule Barkpark.Content.GraphBoundedReadsTest do
  @moduledoc """
  The COST contract of the `/v1/graph` derived reads (`Barkpark.Content.Graph`).

  Every assertion here is a measured QUERY COUNT or a measured ROW COUNT taken
  off `[:barkpark, :repo, :query]` telemetry — never a wall clock. Two
  properties:

    1. `dangling/1` (GET /v1/graph/dangling) issues a CONSTANT number of
       `schema_definitions` reads for an N-document corpus. Before the fix it
       issued one per document: `Content.extract_edges/2` falls back to
       `Content.list_schemas/2` whenever `opts` carries no `:schemas`, and
       `graph.ex` never supplied it. That is the exact cost class `edges.ex`
       already measured at its `:schemas` note — "a 4096-document corpus issued
       4096 identical schema queries (the dominant cost in the /v1/graph
       derivation — measured live: a 34s first paint)" — and which
       `Edges.corpus_edges_for_docs/3` honors. The proof is DIFFERENTIAL (two
       corpus sizes, same count) so it cannot pass vacuously on a fixture that
       never reached the fold: the same run asserts the fold DID produce rows.

    2. `orphans/1` (GET /v1/graph/orphans) no longer materialises the whole
       `content_edges` table. The old shape was
       `select from_id UNION select to_id` over the WHOLE table with no tenancy
       predicate and no LIMIT, folded into a BEAM MapSet — so a member of a
       small workspace paid for every OTHER tenant's edges. We seed a SECOND
       workspace with edges and assert the scoped caller's orphans read pulls
       ZERO `content_edges` rows into the BEAM, and that the other workspace's
       documents never appear in the answer.

  Runs against the test DB. NOT `async` — the telemetry handler filters on the
  emitting pid so a peer's queries can never be counted here, but the row-count
  assertion reads a shared table and stays serial for stability.
  """

  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Graph

  @dataset "graph_bounded_reads_test"

  setup do
    Content.upsert_schema(
      %{"name" => "bnode", "title" => "BNode", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{
        "name" => "blinker",
        "title" => "BLinker",
        "visibility" => "public",
        "fields" => [%{"name" => "rel", "type" => "reference", "refType" => "bnode"}]
      },
      @dataset
    )

    :ok
  end

  # ── Telemetry capture ──────────────────────────────────────────────────────
  #
  # `:telemetry` handlers are GLOBAL, and this suite shares its database with
  # every other agent on the box. The handler therefore drops any event not
  # emitted by THIS test's process, so a peer's queries are structurally
  # uncountable here.
  defp capture_queries(fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _cfg ->
        if self() == test_pid do
          rows =
            case meta[:result] do
              {:ok, %{num_rows: n}} when is_integer(n) -> n
              _ -> 0
            end

          send(test_pid, {ref, meta[:query] || "", rows})
        end
      end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler_id)
      end

    {result, drain(ref, [])}
  end

  defp drain(ref, acc) do
    receive do
      {^ref, sql, rows} -> drain(ref, [{sql, rows} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp mentions(queries, table) do
    Enum.count(queries, fn {sql, _rows} -> String.contains?(sql, ~s("#{table}")) end)
  end

  # The FIRST `FROM "table"` in a rendered Ecto query is that query's OWN
  # source; anything after it is a join or a subquery. Keying on it is what
  # separates "read the edge table" from "correlated to the edge table" — the
  # post-fix orphans read still NAMES content_edges (inside a NOT EXISTS) while
  # reading FROM documents, and only the pre-fix UNION reads FROM the edge
  # table itself.
  defp primary_source(sql) do
    case Regex.run(~r/FROM "(\w+)"/, sql) do
      [_, table] -> table
      _ -> nil
    end
  end

  # Rows this call actually dragged out of `table` and into the BEAM.
  defp rows_read_from(queries, table) do
    queries
    |> Enum.filter(fn {sql, _rows} -> primary_source(sql) == table end)
    |> Enum.map(fn {_sql, rows} -> rows end)
    |> Enum.sum()
  end

  # `Content.list_schemas/2` — the WHOLE-dataset schema LIST, the read the
  # `:schemas` prefetch hoists. Deliberately NOT the per-reference
  # `name = $1 ... LIMIT 1` lookup inside `resolve_target_existence/4`: that
  # one is a different query on a different axis (one per REFERENCE, not one
  # per document) and this row does not claim it.
  defp schema_list_reads(queries) do
    Enum.count(queries, fn {sql, _rows} ->
      primary_source(sql) == "schema_definitions" and not String.contains?(sql, ~s(."name" = ))
    end)
  end

  # ── Fixture helpers ────────────────────────────────────────────────────────

  defp publish_broken_linkers!(prefix, n) do
    for i <- 1..n do
      id = "#{prefix}-#{i}"

      {:ok, _} =
        Content.create_document(
          "blinker",
          %{"_id" => id, "title" => id, "rel" => "#{prefix}-nope-#{i}"},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "blinker", @dataset)
      id
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # (b) dangling/1 — O(1) schema reads, not O(documents)
  # ════════════════════════════════════════════════════════════════════════
  describe "dangling/1 schema-read cost" do
    test "is CONSTANT in the corpus size (pre-fix it was one schema query per document)" do
      small = publish_broken_linkers!("bd-small", 3)

      {rows_small, q_small} =
        capture_queries(fn -> Graph.dangling(dataset: @dataset) end)

      schema_reads_small = schema_list_reads(q_small)

      # NON-VACUITY: the fold really ran over `small`, so a zero-document
      # fixture cannot be what makes the count small.
      for id <- small do
        assert Enum.any?(rows_small, &(&1.from_id == id)),
               "the fold never reached #{id}: #{inspect(rows_small)}"
      end

      # Now TRIPLE the corpus in the same dataset.
      more = publish_broken_linkers!("bd-large", 6)

      {rows_large, q_large} =
        capture_queries(fn -> Graph.dangling(dataset: @dataset) end)

      schema_reads_large = schema_list_reads(q_large)

      for id <- more do
        assert Enum.any?(rows_large, &(&1.from_id == id)),
               "the fold never reached #{id}"
      end

      assert length(rows_large) == length(rows_small) + 6,
             "the larger corpus must actually produce more dangling rows"

      # THE MEASUREMENT. 3 documents and 9 documents, one schema list each.
      assert schema_reads_small == schema_reads_large,
             """
             schema_definitions reads scale with the corpus:
               3 documents -> #{schema_reads_small} reads
               9 documents -> #{schema_reads_large} reads
             The `:schemas` prefetch (edges.ex:286-292) is not reaching
             extract_edges/2 from Graph.dangling/1.
             """

      assert schema_reads_large <= 1,
             "expected at most ONE hoisted schema list, got #{schema_reads_large}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # (a) orphans/1 — no whole-table content_edges scan, no cross-tenant cost
  # ════════════════════════════════════════════════════════════════════════
  describe "orphans/1 tenancy + edge-table cost" do
    test "a scoped caller pulls ZERO content_edges rows and never sees another workspace's docs" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      scope_b = [workspace_id: ws_b.id, project_id: proj_b.id, dataset: @dataset]

      # Workspace A: ONE isolated document, no edges at all.
      {:ok, _} =
        create_document_in!(ws_a, proj_a, "bnode", %{"_id" => "orph-a-lonely"}, @dataset)

      {:ok, _} =
        Content.publish_document("orph-a-lonely", "bnode", @dataset,
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      # Workspace B: a connected pair PLUS a doc that is an orphan *there*.
      # Every one of B's edges is a row the OLD orphans/1 dragged into A's
      # request as a MapSet member.
      for id <- ~w(orph-b-src orph-b-dst orph-b-lonely) do
        {:ok, _} = create_document_in!(ws_b, proj_b, "bnode", %{"_id" => id}, @dataset)

        {:ok, _} =
          Content.publish_document(id, "bnode", @dataset,
            workspace_id: ws_b.id,
            project_id: proj_b.id
          )
      end

      Content.add_edges(
        [%{from_id: "orph-b-src", to_id: "orph-b-dst", kind: "references"}],
        scope_b
      )

      # Non-vacuity for the fixture: B's edge really materialised, so the
      # "A sees no edge rows" assertion below is not green because the edge
      # table was empty.
      {b_orphans, q_b} =
        capture_queries(fn -> Graph.orphans(scope_b) end)

      b_ids = Enum.map(b_orphans, & &1.doc_id)
      assert "orph-b-lonely" in b_ids
      refute "orph-b-src" in b_ids, "B's connected source must not be an orphan"
      refute "orph-b-dst" in b_ids, "B's connected target must not be an orphan"

      assert mentions(q_b, "content_edges") > 0,
             "orphans/1 must still consult content_edges — otherwise the " <>
               "connectivity answer above is vacuous"

      # THE MEASUREMENT + THE LEAK. A's request must not carry B's rows —
      # neither into the answer nor into the BEAM.
      {a_orphans, q_a} =
        capture_queries(fn ->
          Graph.orphans(workspace_id: ws_a.id, project_id: proj_a.id, dataset: @dataset)
        end)

      a_ids = Enum.map(a_orphans, & &1.doc_id)
      assert "orph-a-lonely" in a_ids
      refute "orph-b-lonely" in a_ids, "workspace B's orphan leaked into A's listing"
      refute "orph-b-src" in a_ids
      refute "orph-b-dst" in a_ids

      assert rows_read_from(q_a, "content_edges") == 0,
             """
             the scoped orphans read pulled #{rows_read_from(q_a, "content_edges")} \
             content_edges row(s) into the BEAM. The connected-set must be a \
             correlated NOT EXISTS against the scoped document subquery, not a \
             UNION of every edge endpoint in the instance.
             """
    end
  end
end
