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
end
