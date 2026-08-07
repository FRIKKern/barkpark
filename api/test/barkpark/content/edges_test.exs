defmodule Barkpark.Content.EdgesTest do
  @moduledoc """
  Tests for `Barkpark.Content.Edges` — surfaces NOT covered by edge_extract_test:

    * `list_inbound_edges/2`  — reverse scan of content_edges by to_id.
    * `list_inbound_edges/2` with `:kind` filter.
    * `find_referencing_docs/3` — schema-driven SQL scan that finds documents
      whose scalar `reference` field points at the given doc_id.
    * `find_referencing_docs/3` returns empty when no schema has reference fields.

  Runs against the test DB (Postgres on :5432).
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  @dataset "edges_module_test"

  setup do
    # `target` — the type being pointed AT.
    Content.upsert_schema(
      %{"name" => "target", "title" => "Target", "visibility" => "public", "fields" => []},
      @dataset
    )

    # `pointer` — has a scalar `reference` field (refType "target") and a second
    # reference field of a different kind so we can test kind-filtering.
    Content.upsert_schema(
      %{
        "name" => "pointer",
        "title" => "Pointer",
        "visibility" => "public",
        "fields" => [
          %{"name" => "rel", "type" => "reference", "refType" => "target"},
          %{"name" => "alt", "type" => "reference", "refType" => "target"}
        ]
      },
      @dataset
    )

    # `plain` — no reference fields; used to confirm find_referencing_docs
    # never surfaces non-reference types.
    Content.upsert_schema(
      %{"name" => "plain", "title" => "Plain", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  defp publish!(type, id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(
        type,
        Map.merge(%{"_id" => id, "title" => id}, attrs),
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, type, @dataset)
    doc
  end

  describe "list_inbound_edges/2" do
    test "returns edges pointing at the given to_id" do
      publish!("target", "tgt-1")
      src = publish!("pointer", "ptr-1", %{"rel" => "tgt-1"})

      {:ok, from_doc} = Content.get_document("ptr-1", "pointer", @dataset)
      {:ok, to_doc} = Content.get_document("tgt-1", "target", @dataset)

      # Materialise the edge via add_edges.
      edge_maps = Content.extract_edges(src)
      Content.add_edges(edge_maps, dataset: @dataset)

      inbound = Content.list_inbound_edges(to_doc.id)

      assert length(inbound) >= 1
      assert Enum.any?(inbound, fn e -> e.from_id == from_doc.id and e.to_id == to_doc.id end)
    end

    test "returns empty when no edges point at the id" do
      publish!("target", "tgt-orphan")
      {:ok, to_doc} = Content.get_document("tgt-orphan", "target", @dataset)

      assert Content.list_inbound_edges(to_doc.id) == []
    end

    test "kind filter narrows to only edges of the requested kind" do
      publish!("target", "tgt-kind")
      src = publish!("pointer", "ptr-kind", %{"rel" => "tgt-kind", "alt" => "tgt-kind"})

      {:ok, to_doc} = Content.get_document("tgt-kind", "target", @dataset)

      edge_maps = Content.extract_edges(src)
      Content.add_edges(edge_maps, dataset: @dataset)

      inbound_all = Content.list_inbound_edges(to_doc.id)
      inbound_rel = Content.list_inbound_edges(to_doc.id, kind: "rel")
      inbound_alt = Content.list_inbound_edges(to_doc.id, kind: "alt")

      # Both fields produce an edge to the same target — should be two total.
      assert length(inbound_all) == 2
      assert length(inbound_rel) == 1
      assert Enum.all?(inbound_rel, &(&1.kind == "rel"))
      assert length(inbound_alt) == 1
      assert Enum.all?(inbound_alt, &(&1.kind == "alt"))
    end
  end

  describe "find_referencing_docs/3" do
    test "returns docs whose scalar reference field points at the given doc_id" do
      publish!("target", "tgt-ref")
      publish!("pointer", "ptr-ref", %{"rel" => "tgt-ref"})

      refs = Content.find_referencing_docs("tgt-ref", @dataset)

      assert length(refs) == 1
      [hit] = refs
      assert hit.doc_id == "ptr-ref"
      assert hit.type == "pointer"
      assert hit.field == "rel"
    end

    test "returns empty when no document references the given doc_id" do
      publish!("target", "tgt-nobody")

      refs = Content.find_referencing_docs("tgt-nobody", @dataset)
      assert refs == []
    end

    test "handles published_id coalescion — draft prefix stripped before scan" do
      publish!("target", "tgt-coal")
      publish!("pointer", "ptr-coal", %{"rel" => "tgt-coal"})

      # Passing the draft-prefixed id must find the same referencing doc.
      refs = Content.find_referencing_docs("drafts.tgt-coal", @dataset)

      assert Enum.any?(refs, &(&1.doc_id == "ptr-coal")),
             "find_referencing_docs must strip the drafts. prefix before scanning"
    end
  end

  describe "disconnect_references/3 — drains past the scan cap" do
    test "disconnects ALL scalar referencers even when they exceed one scan page" do
      publish!("target", "tgt-many")

      # 7 referencers. `find_referencing_docs`'s scan is capped (prod default
      # 1000); we force a tiny page via `limit: 2` so the SAME multi-page drain
      # path is exercised with 4 pages (2+2+2+1) instead of needing 1000+ docs.
      ids = for n <- 1..7, do: "ptr-many-#{n}"
      Enum.each(ids, fn id -> publish!("pointer", id, %{"rel" => "tgt-many"}) end)

      # Sanity: with the same lowered cap the scan sees only one page (2).
      assert length(Content.find_referencing_docs("tgt-many", @dataset, limit: 2)) == 2

      Content.disconnect_references("tgt-many", @dataset, limit: 2)

      # NOTHING dangles past the cap — every referencer was drained.
      assert Content.find_referencing_docs("tgt-many", @dataset) == []
      assert Content.find_referencing_docs("tgt-many", @dataset, limit: 2) == []

      # Each source doc actually had the reference field stripped.
      Enum.each(ids, fn id ->
        {:ok, doc} = Content.get_document(id, "pointer", @dataset)

        refute Map.has_key?(doc.content || %{}, "rel"),
               "#{id} should have had its scalar reference stripped by the drain"
      end)
    end
  end

  # Count [:barkpark, :repo, :query] emissions raised BY THIS PROCESS while
  # `fun` runs. Returns {result, query_count}.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = {:edges_query_counter, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: send(test_pid, :repo_query)
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_query_count(0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_query_count(n) do
    receive do
      :repo_query -> drain_query_count(n + 1)
    after
      0 -> n
    end
  end

  # 20 pointer docs × 2 reference fields = 40 edges — the shape of the corpus
  # fold, small enough to run in-suite.
  defp seed_corpus!(n) do
    publish!("target", "rt-target")

    docs =
      for i <- 1..n do
        publish!("pointer", "rt-ptr-#{i}", %{"rel" => "rt-target", "alt" => "rt-missing"})
      end

    {docs, Content.list_schemas(@dataset, [])}
  end

  # ════════════════════════════════════════════════════════════════════════
  # extract_edges/2 `dangling: :skip` — the OPT-IN round-trip escape
  #
  # Dangling resolution costs ONE un-batched DB round-trip per reference value
  # per document. /v1/graph's corpus derivation discards the boolean (it keeps
  # from_id/to_id/kind/weight/plugin_source), so it paid ~1,300 serial queries
  # per call — and held a pool connection across all of them — for a value
  # nobody read. `dangling: :skip` removes exactly those queries.
  #
  # COUNTING METHOD: the Ecto telemetry event [:barkpark, :repo, :query] (the
  # Repo's default prefix), attached for the duration of the call and filtered
  # to THIS test process so a concurrent async test cannot inflate the count.
  # ════════════════════════════════════════════════════════════════════════
  describe "extract_edges/2 dangling round-trips" do
    test "DEFAULT resolves dangling and pays one round-trip per edge" do
      {docs, schemas} = seed_corpus!(20)

      {edges, queries} =
        count_queries(fn ->
          Enum.flat_map(docs, fn d -> Content.extract_edges(d, schemas: schemas) end)
        end)

      assert length(edges) == 40

      # Every edge carries a real boolean: "rel" resolves, "alt" dangles.
      assert Enum.all?(edges, &is_boolean(&1.dangling))
      assert Enum.all?(Enum.filter(edges, &(&1.field == "rel")), &(&1.dangling == false))
      assert Enum.all?(Enum.filter(edges, &(&1.field == "alt")), &(&1.dangling == true))

      # One existence query per edge, un-batched — the cost being removed.
      assert queries >= 40,
             "expected >= one existence round-trip per edge, counted #{queries}"
    end

    test "dangling: :skip issues ZERO queries and emits the same edges with dangling: nil" do
      {docs, schemas} = seed_corpus!(20)

      {default_edges, default_queries} =
        count_queries(fn ->
          Enum.flat_map(docs, fn d -> Content.extract_edges(d, schemas: schemas) end)
        end)

      {skipped_edges, skipped_queries} =
        count_queries(fn ->
          Enum.flat_map(docs, fn d ->
            Content.extract_edges(d, schemas: schemas, dangling: :skip)
          end)
        end)

      # THE MEASUREMENT: 40 edges → 40+ round-trips by default, ZERO under the
      # flag. On the live 4096-doc corpus this is the ~1,300 → 0 collapse; the
      # /v1/graph call keeps only its ~10 structural queries (1 schemas list,
      # one list per type, one count per capped type).
      assert default_queries >= 40
      assert skipped_queries == 0, "expected no DB round-trips, counted #{skipped_queries}"

      # Same edges, same order, same keys — ONLY `dangling` differs, and it
      # differs to nil ("not computed"), never to a fabricated false.
      assert length(skipped_edges) == length(default_edges)
      assert Enum.all?(skipped_edges, &(&1.dangling == nil))

      assert Enum.map(skipped_edges, &Map.keys/1) == Enum.map(default_edges, &Map.keys/1)

      assert Enum.map(skipped_edges, &Map.delete(&1, :dangling)) ==
               Enum.map(default_edges, &Map.delete(&1, :dangling))
    end

    test "the DEFAULT is unchanged for callers that pass no :dangling opt" do
      publish!("target", "rt-live")
      src = publish!("pointer", "rt-default", %{"rel" => "rt-live", "alt" => "rt-gone"})

      # No opts at all — EdgeProjector / Graph.dangling / corpus_edges shape.
      edges = Content.extract_edges(src)

      assert Enum.find(edges, &(&1.field == "rel")).dangling == false
      assert Enum.find(edges, &(&1.field == "alt")).dangling == true
    end
  end
end
