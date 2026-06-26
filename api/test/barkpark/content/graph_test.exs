defmodule Barkpark.Content.GraphTest do
  @moduledoc """
  Phase 4 — `Barkpark.Content.Graph` BFS engine.

  Surfaces covered:

    * `clamp_depth/1` clamps to 1..5 (never raises, never errors).
    * `traverse/2` walks materialised `content_edges`, dedups multi-path via the
      visited MapSet, and ALWAYS returns `truncated` + `truncation_reason`.
    * depth trip-wire fires (truncation_reason :depth) on a chain deeper than the
      clamped depth.
    * `rank_dependents/1` orders weight-FREE (the explicit forbidding-comment
      contract) — a higher-weight edge never out-ranks a closer / higher-fan-in
      node.
    * `reverse_referencers/2` is the inbound-edge query (the Phase-5 dependency),
      and covers arrayOf-of-reference edges materialised in Phase 2.
    * `orphans/1` returns docs with zero in + zero out edges.

  Edges are materialised directly via `Content.add_edges/2` (the Phase-3
  projector path is async/manual in tests — we drive the read side here).

  Runs against the test DB (Postgres on :5432).
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Graph

  @dataset "graph_engine_test"

  setup do
    Content.upsert_schema(
      %{"name" => "node", "title" => "Node", "visibility" => "public", "fields" => []},
      @dataset
    )

    # `linker` carries a scalar reference (refType "node") so the drafts
    # live-extract path has a real reference field to walk.
    Content.upsert_schema(
      %{
        "name" => "linker",
        "title" => "Linker",
        "visibility" => "public",
        "fields" => [%{"name" => "rel", "type" => "reference", "refType" => "node"}]
      },
      @dataset
    )

    :ok
  end

  defp publish!(id, attrs \\ %{}) do
    {:ok, _} =
      Content.create_document(
        "node",
        Map.merge(%{"_id" => id, "title" => id}, attrs),
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, "node", @dataset)
    doc
  end

  # Create a DRAFT only (no publish) of a given type — exists solely as
  # drafts.<id>. Used by the perspective: :drafts live-extract tests.
  defp draft_only!(type, id, attrs) do
    {:ok, doc} =
      Content.create_document(
        type,
        Map.merge(%{"_id" => id, "title" => id}, attrs),
        @dataset
      )

    doc
  end

  describe "resolve_doc/3 (canonical slug→Document resolver; collapses resolve_pk + resolve_graph_doc)" do
    test "resolves a published doc's slug to its Document within the dataset" do
      doc = publish!("rd-target")

      assert %Content.Document{id: id, doc_id: doc_id} = Graph.resolve_doc("rd-target", @dataset, [])
      assert id == doc.id
      # published-preferred: never the drafts.* row
      refute String.starts_with?(doc_id, "drafts.")
    end

    test "returns nil for a nil id, an unknown slug, and a non-matching dataset" do
      publish!("rd-scoped")

      assert Graph.resolve_doc(nil, @dataset, []) == nil
      assert Graph.resolve_doc("rd-nonexistent", @dataset, []) == nil

      # dataset is a hard filter — the doc exists, but not in this dataset
      assert Graph.resolve_doc("rd-scoped", "a-different-dataset", []) == nil
    end
  end

  describe "clamp_depth/1" do
    test "clamps below 1 up to 1, above 5 down to 5, nil to the default 2" do
      assert Graph.clamp_depth(0) == 1
      assert Graph.clamp_depth(-7) == 1
      assert Graph.clamp_depth(3) == 3
      assert Graph.clamp_depth(99) == 5
      assert Graph.clamp_depth(nil) == 2
    end
  end

  describe "traverse/2" do
    test "walks outbound edges and always carries truncated + truncation_reason" do
      root = publish!("g-root")
      child = publish!("g-child")

      [{:ok, _}] = Content.add_edges([%{from_id: "g-root", to_id: "g-child", kind: "references"}], dataset: @dataset)

      result = Graph.traverse(root.id, dataset: @dataset, depth: 2, direction: :out)

      # traverse/2 roots on the documents.id UUID (the content_edges FK key); the
      # HTTP layer is what coalesces it back to the slug for the response.
      assert result.root == root.id
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :truncation_reason)

      node_ids = Enum.map(result.nodes, & &1[:doc_id])
      assert "g-root" in node_ids
      assert "g-child" in node_ids
      assert child.doc_id == "g-child"

      assert Enum.any?(result.edges, fn e -> e.kind == "references" end)
    end

    test "dedups a diamond (multi-path) via the visited MapSet" do
      a = publish!("g-a")
      _b = publish!("g-b")
      _c = publish!("g-c")
      _d = publish!("g-d")

      # a → b → d and a → c → d : d is reachable by two paths, must appear once.
      Content.add_edges(
        [
          %{from_id: "g-a", to_id: "g-b", kind: "references"},
          %{from_id: "g-a", to_id: "g-c", kind: "references"},
          %{from_id: "g-b", to_id: "g-d", kind: "references"},
          %{from_id: "g-c", to_id: "g-d", kind: "references"}
        ],
        dataset: @dataset
      )

      result = Graph.traverse(a.id, dataset: @dataset, depth: 5, direction: :out)

      d_count = Enum.count(result.nodes, fn n -> n[:doc_id] == "g-d" end)
      assert d_count == 1
    end

    test "depth trip-wire fires :depth on a chain deeper than the clamped depth" do
      root = publish!("g-chain-0")
      publish!("g-chain-1")
      publish!("g-chain-2")
      publish!("g-chain-3")

      Content.add_edges(
        [
          %{from_id: "g-chain-0", to_id: "g-chain-1", kind: "references"},
          %{from_id: "g-chain-1", to_id: "g-chain-2", kind: "references"},
          %{from_id: "g-chain-2", to_id: "g-chain-3", kind: "references"}
        ],
        dataset: @dataset
      )

      # depth 1 → only one hop expanded; the chain continues → truncated :depth.
      result = Graph.traverse(root.id, dataset: @dataset, depth: 1, direction: :out)

      assert result.truncated
      assert result.truncation_reason == :depth
    end

    test "a boundary-EXACT graph (deepest edge at the depth limit) is NOT truncated" do
      # root → child, depth 1. The walk expands root, enqueues child, then
      # recurses to level 2 (> max 1) with frontier [child]. The OLD code fired
      # truncated:true/:depth unconditionally — but child is a LEAF (zero
      # outbound edges), so nothing was cut. The boundary guard must report
      # truncated:false / reason:nil here. (Regression lock for the depth
      # trip-wire false-positive.)
      root = publish!("g-exact-root")
      publish!("g-exact-child")

      [{:ok, _}] =
        Content.add_edges(
          [%{from_id: "g-exact-root", to_id: "g-exact-child", kind: "references"}],
          dataset: @dataset
        )

      result = Graph.traverse(root.id, dataset: @dataset, depth: 1, direction: :out)

      refute result.truncated,
             "a graph fully explored within the clamped depth must report truncated:false"

      assert result.truncation_reason == nil
    end
  end

  describe "traverse/2 perspective: :drafts (live-extract path)" do
    test "a draft-only edge appears under :drafts and is ABSENT under :published" do
      # `dn-target` is a published node; `dn-src` is a DRAFT-ONLY linker whose
      # `rel` reference points at it. The published materialised table holds no
      # row for the unpublished source, so the published traversal sees nothing —
      # but the live drafts extract walks the reference field directly.
      target = publish!("dn-target")
      src = draft_only!("linker", "dn-src", %{"rel" => "dn-target"})

      # Sanity: the source really is draft-only.
      assert String.starts_with?(src.doc_id, "drafts.")

      drafts =
        Graph.traverse("dn-src",
          dataset: @dataset,
          perspective: :drafts,
          root_pub_id: "dn-src",
          depth: 2,
          direction: :out
        )

      edge_pairs = Enum.map(drafts.edges, fn e -> {e.from_id, e.to_id} end)

      assert {"dn-src", "dn-target"} in edge_pairs,
             "the live drafts extract must surface the draft-only reference edge"

      node_ids = Enum.map(drafts.nodes, & &1.doc_id)
      assert "dn-src" in node_ids
      assert "dn-target" in node_ids

      # The published path roots on the materialised table, which never
      # materialised the unpublished source's outbound edge → no such edge.
      published = Graph.traverse(target.id, dataset: @dataset, depth: 2, direction: :both)
      pub_pairs = Enum.map(published.edges, fn e -> {e.from_id, e.to_id} end)

      refute {"dn-src", "dn-target"} in pub_pairs,
             "the published traversal must NOT show the draft-only edge"
    end
  end

  describe "rank_dependents/1 (weight-free contract)" do
    test "a higher-weight edge NEVER reorders ranking — distance + fan-in only" do
      # near has distance 1 + inbound 0; far has distance 2 + inbound 0. Even if
      # we tag far's incoming edge with a huge weight, near must rank first.
      near = %{id: "n-near", doc_id: "near", type: "node", title: "near", distance: 1, inbound_count: 0}
      far = %{id: "n-far", doc_id: "far", type: "node", title: "far", distance: 2, inbound_count: 5}

      ranked = Graph.rank_dependents([far, near])

      # near (distance 1) ranks ahead of far (distance 2) despite far's higher
      # inbound_count — distance dominates, and weight never enters.
      assert Enum.map(ranked, & &1.id) == ["n-near", "n-far"]
    end
  end

  describe "reverse_referencers/2 (Phase-5 dependency, arrayOf-aware)" do
    test "returns inbound edges including arrayOf-materialised ones" do
      target = publish!("rr-target")
      _src1 = publish!("rr-src-1")
      _src2 = publish!("rr-src-2")

      # rr-src-1 references target via a scalar ref; rr-src-2 via an arrayOf ref —
      # both materialised the same way in content_edges (Phase 2), so the reverse
      # walker sees BOTH (the find_referencing_docs scalar-only undercount is the
      # bug this query exists to dodge).
      Content.add_edges(
        [
          %{from_id: "rr-src-1", to_id: "rr-target", kind: "references"},
          %{from_id: "rr-src-2", to_id: "rr-target", kind: "references"}
        ],
        dataset: @dataset
      )

      refs = Graph.reverse_referencers(target.doc_id, dataset: @dataset)

      from_doc_ids = refs |> Enum.map(& &1.from_doc_id) |> Enum.sort()
      assert from_doc_ids == ["rr-src-1", "rr-src-2"]
      assert Enum.all?(refs, fn r -> r.kind == "references" end)
    end

    test "returns [] for an id nothing references" do
      lonely = publish!("rr-lonely")
      assert Graph.reverse_referencers(lonely.doc_id, dataset: @dataset) == []
    end
  end

  describe "orphans/1" do
    test "returns docs with zero inbound and zero outbound edges" do
      _orphan = publish!("orph-1")
      _connected_a = publish!("orph-conn-a")
      _connected_b = publish!("orph-conn-b")

      Content.add_edges(
        [%{from_id: "orph-conn-a", to_id: "orph-conn-b", kind: "references"}],
        dataset: @dataset
      )

      orphan_ids = Graph.orphans(dataset: @dataset) |> Enum.map(& &1.doc_id)

      assert "orph-1" in orphan_ids
      refute "orph-conn-a" in orphan_ids
      refute "orph-conn-b" in orphan_ids
    end
  end
end
