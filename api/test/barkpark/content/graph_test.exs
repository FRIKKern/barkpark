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

      assert %Content.Document{id: id, doc_id: doc_id} =
               Graph.resolve_doc("rd-target", @dataset, [])

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

      [{:ok, _}] =
        Content.add_edges([%{from_id: "g-root", to_id: "g-child", kind: "references"}],
          dataset: @dataset
        )

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
      near = %{
        id: "n-near",
        doc_id: "near",
        type: "node",
        title: "near",
        distance: 1,
        inbound_count: 0
      }

      far = %{
        id: "n-far",
        doc_id: "far",
        type: "node",
        title: "far",
        distance: 2,
        inbound_count: 5
      }

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

  describe "valueref used-by / impact reads (lvw-t3)" do
    # The body-walk extractor (#714) materialises `kind: "valueref"` edges
    # (referencing paper → canonical value doc, plugin_source "bulldocs").
    # These reads are what the used-by/impact panels compose — NO new graph
    # code, so these tests pin the existing engine's behaviour over
    # valueref-kind rows. The corpus is published-perspective only (D1):
    # a draft-only referencing paper has no edge row here BY DESIGN.

    test "reverse_referencers surfaces the docs that valueref-reference a canonical value doc" do
      canonical = publish!("vr-canonical")
      _user1 = publish!("vr-user-1")
      _user2 = publish!("vr-user-2")

      Content.add_edges(
        [
          %{
            from_id: "vr-user-1",
            to_id: "vr-canonical",
            kind: "valueref",
            plugin_source: "bulldocs"
          },
          %{
            from_id: "vr-user-2",
            to_id: "vr-canonical",
            kind: "valueref",
            plugin_source: "bulldocs"
          }
        ],
        dataset: @dataset
      )

      refs = Graph.reverse_referencers(canonical.doc_id, dataset: @dataset)

      assert refs |> Enum.map(& &1.from_doc_id) |> Enum.sort() == ["vr-user-1", "vr-user-2"]
      # The panels partition on kind — it must round-trip verbatim (`valueref`,
      # never `value-ref`), and carry the extractor's plugin_source.
      assert Enum.all?(refs, &(&1.kind == "valueref"))
      assert Enum.all?(refs, &(&1.via_field == "valueref"))
      assert Enum.all?(refs, &(&1.plugin_source == "bulldocs"))
    end

    test "traverse (:both) carries the valueref edge and ranks the referencing doc as a dependent" do
      canonical = publish!("vr-t-canonical")
      user = publish!("vr-t-user")

      Content.add_edges(
        [
          %{
            from_id: "vr-t-user",
            to_id: "vr-t-canonical",
            kind: "valueref",
            plugin_source: "bulldocs"
          }
        ],
        dataset: @dataset
      )

      result = Graph.traverse(canonical.id, dataset: @dataset, direction: :both, depth: 2)

      # The blast-radius pane reads exactly this payload (PaneBuilder →
      # GraphView): the valueref edge must arrive kind-intact and the
      # referencing doc must rank as a dependent of the canonical value doc.
      assert Enum.any?(result.edges, fn e ->
               e.kind == "valueref" and e.from_id == user.id and e.to_id == canonical.id
             end)

      assert Enum.any?(result.dependents, fn d -> d.doc_id == "vr-t-user" end)
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

  # ════════════════════════════════════════════════════════════════════════
  # Owner-ACL on the graph read path (MEDIUM-5 + LOW-12)
  #
  # The graph hydration reads emit a document's title + doc_id + existence.
  # On an `owner_scoped` type, a non-owner (including anonymous and a
  # context-less internal read) must NOT surface another user's node through
  # reverse_referencers / traverse / orphans. The owner, an admin, and an
  # api_token still see it. Non-owner_scoped nodes are unchanged.
  # ════════════════════════════════════════════════════════════════════════
  describe "owner-ACL on graph reads (MEDIUM-5 / LOW-12)" do
    alias Barkpark.Content.CallerContext

    setup do
      Content.upsert_schema(
        %{
          "name" => "owned_node",
          "title" => "Owned Node",
          "owner_scoped" => true,
          "fields" => [%{"name" => "rel", "type" => "reference", "refType" => "node"}]
        },
        @dataset
      )

      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      %{user_a: user_a, user_b: user_b}
    end

    defp user_ctx(uid), do: [caller_context: CallerContext.from_user(uid, roles: [])]

    defp admin_ctx,
      do: [caller_context: %CallerContext{principal_type: :user, user_id: "adm", is_admin: true}]

    defp token_ctx,
      do: [caller_context: %CallerContext{principal_type: :api_token, token_id: "tok"}]

    defp anon_ctx, do: [caller_context: CallerContext.anonymous()]

    # Create + publish an owner_scoped node owned by `uid`. The create stamps
    # owner_id from the caller_context; publish now CARRIES owner_id onto the
    # published row (WriteScope.inherit_scope_attrs, MEDIUM-5 write-path fix), so
    # the read-side owner-ACL protects the REAL published row — no force-stamp.
    # This asserts the published row actually carries owner_id, which is the hard
    # prerequisite for the graph/Query owner-scoping to be effective in prod.
    defp owned_publish!(id, uid) do
      {:ok, _} =
        Content.create_document(
          "owned_node",
          %{"_id" => id, "title" => "secret-#{id}"},
          @dataset,
          user_ctx(uid)
        )

      {:ok, doc} = Content.publish_document(id, "owned_node", @dataset, user_ctx(uid))

      # Prove publish carried owner_id onto the published row (no force-stamp).
      assert doc.owner_id == uid

      doc
    end

    test "reverse_referencers hides an owner_scoped source owned by another user",
         %{user_a: a, user_b: b} do
      target = publish!("oa-target")
      _src = owned_publish!("oa-secret-src", a)

      Content.add_edges(
        [%{from_id: "oa-secret-src", to_id: "oa-target", kind: "references"}],
        dataset: @dataset
      )

      from_ids = fn opts ->
        target.doc_id
        |> Graph.reverse_referencers([dataset: @dataset] ++ opts)
        |> Enum.map(& &1.from_doc_id)
      end

      # Owner sees the source; admin + token see it (bypass).
      assert "oa-secret-src" in from_ids.(user_ctx(a))
      assert "oa-secret-src" in from_ids.(admin_ctx())
      assert "oa-secret-src" in from_ids.(token_ctx())

      # NON-owner, anonymous, and a context-less read see NOTHING — not the
      # title, not the doc_id, not even a stub entry (existence is hidden).
      assert from_ids.(user_ctx(b)) == []
      assert from_ids.(anon_ctx()) == []
      assert Graph.reverse_referencers(target.doc_id, dataset: @dataset) == []
    end

    test "traverse does not hydrate an owner_scoped node owned by another user",
         %{user_a: a, user_b: b} do
      root = publish!("ot-root")
      secret = owned_publish!("ot-secret", a)

      Content.add_edges(
        [%{from_id: "ot-root", to_id: "ot-secret", kind: "references"}],
        dataset: @dataset
      )

      traverse = fn opts ->
        Graph.traverse(root.id, [dataset: @dataset, depth: 2, direction: :out] ++ opts)
      end

      node_doc_ids = fn opts -> traverse.(opts) |> Map.fetch!(:nodes) |> Enum.map(& &1.doc_id) end

      # The secret node's internal documents.id UUID — the value the edge list
      # would otherwise leak via from_id/to_id even when the node is hidden.
      secret_pk = secret.id

      edge_endpoints = fn opts ->
        traverse.(opts)
        |> Map.fetch!(:edges)
        |> Enum.flat_map(fn e -> [e.from_id, e.to_id] end)
      end

      # Owner sees the secret node in the graph; a non-owner does not.
      assert "ot-secret" in node_doc_ids.(user_ctx(a))
      refute "ot-secret" in node_doc_ids.(user_ctx(b))
      refute "ot-secret" in node_doc_ids.(anon_ctx())

      # Owner's edge list carries the edge to the secret node...
      assert secret_pk in edge_endpoints.(user_ctx(a))

      # ...but a non-owner / anonymous caller sees NO edge referencing the hidden
      # node's UUID (edge-half of MEDIUM-5: the edge list cannot out a node the
      # node list hides — existence, internal id, and topology all stay hidden).
      refute secret_pk in edge_endpoints.(user_ctx(b))
      refute secret_pk in edge_endpoints.(anon_ctx())
    end

    test "orphans hides an owner_scoped orphan owned by another user",
         %{user_a: a, user_b: b} do
      _secret = owned_publish!("oo-secret", a)

      orphan_ids = fn opts ->
        Graph.orphans([dataset: @dataset] ++ opts) |> Enum.map(& &1.doc_id)
      end

      assert "oo-secret" in orphan_ids.(user_ctx(a))
      assert "oo-secret" in orphan_ids.(admin_ctx())
      refute "oo-secret" in orphan_ids.(user_ctx(b))
      refute "oo-secret" in orphan_ids.(anon_ctx())
      # Context-less read FAILS CLOSED (LOW-12): an owned orphan is hidden.
      refute "oo-secret" in (Graph.orphans(dataset: @dataset) |> Enum.map(& &1.doc_id))
    end

    test "a non-owner_scoped node stays visible to every caller (byte-identical)",
         %{user_b: b} do
      target = publish!("on-target")
      _src = publish!("on-plain-src")

      Content.add_edges(
        [%{from_id: "on-plain-src", to_id: "on-target", kind: "references"}],
        dataset: @dataset
      )

      from_ids = fn opts ->
        target.doc_id
        |> Graph.reverse_referencers([dataset: @dataset] ++ opts)
        |> Enum.map(& &1.from_doc_id)
      end

      assert "on-plain-src" in from_ids.(user_ctx(b))
      assert "on-plain-src" in from_ids.(anon_ctx())

      assert "on-plain-src" in (target.doc_id
                                |> Graph.reverse_referencers(dataset: @dataset)
                                |> Enum.map(& &1.from_doc_id))
    end
  end
end
