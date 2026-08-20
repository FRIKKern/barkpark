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

    # `paper` has NO core reference fields — its edges come ONLY from the
    # Bulldocs plugin extractor (body-walk valueref/wikilink/ref), so the
    # drafts plugin-fold tests below cannot pass vacuously via core edges.
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
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

    # lvw-t12 (wire §7(2)): the drafts traverse folds the plugin
    # resolve_extract_edges chain, not just core extract_edges.
    test "a DRAFT paper's plugin-extracted valueref/task edges appear under :drafts and NOT under :published" do
      target = publish!("dp-val-target")

      body = [
        %{
          "type" => "paragraph",
          "children" => [
            %{"type" => "valueref", "target" => "dp-val-target"},
            # A task chip is a plain wikilink whose docId IS the task doc id;
            # it stays dangling here (no such doc) → phantom, edge still shown.
            %{"type" => "wikilink", "docId" => "dp-chip-task", "target" => "Chip task"}
          ]
        }
      ]

      src = draft_only!("paper", "dp-src", %{"body" => body})
      assert String.starts_with?(src.doc_id, "drafts.")

      drafts =
        Graph.traverse("dp-src",
          dataset: @dataset,
          perspective: :drafts,
          root_pub_id: "dp-src",
          depth: 2,
          direction: :out
        )

      triples = Enum.map(drafts.edges, fn e -> {e.from_id, e.to_id, e.kind} end)

      assert {"dp-src", "dp-val-target", "valueref"} in triples,
             "the drafts traverse must surface the draft paper's plugin-extracted valueref edge"

      assert {"dp-src", "dp-chip-task", "references"} in triples,
             "the drafts traverse must surface the task-chip wikilink references edge"

      # Rendered drafts edges carry the plugin's source (published-path parity).
      assert Enum.any?(drafts.edges, fn e -> e.plugin_source == "bulldocs" end)

      # Phantom nodes carry :broken_id (no :doc_id key) — Map.get, not dot.
      node_ids = Enum.map(drafts.nodes, &Map.get(&1, :doc_id))
      assert "dp-val-target" in node_ids, "a resolvable valueref target is a real node"

      # The dangling task-chip target surfaces as a phantom, never a real node.
      phantom = Enum.find(drafts.nodes, fn n -> n[:broken_id] == "dp-chip-task" end)
      assert phantom, "an unresolvable task-chip target must surface as a phantom node"
      assert phantom.phantom == true

      # Publish-gating: the materialised published graph holds NO row for the
      # unpublished paper's edges — nothing until publish + projection.
      published = Graph.traverse(target.id, dataset: @dataset, depth: 2, direction: :both)
      pub_pairs = Enum.map(published.edges, fn e -> {e.from_id, e.to_id} end)

      refute {"dp-src", "dp-val-target"} in pub_pairs,
             "the published graph must NOT show the draft paper's valueref edge before publish"
    end

    test "a valueref to a DRAFT-ONLY target traverses (drafts-corpus dangling lens)" do
      # The target exists ONLY as a draft — invisible under the :published lens,
      # but a member of the scoped drafts corpus, so the plugin edge is
      # non-dangling here and the BFS walks INTO it (the drafts surface sees
      # the drafts world).
      _target = draft_only!("node", "dp-draft-target", %{})

      body = [%{"type" => "valueref", "target" => "dp-draft-target"}]
      _src = draft_only!("paper", "dp-src-2", %{"body" => body})

      drafts =
        Graph.traverse("dp-src-2",
          dataset: @dataset,
          perspective: :drafts,
          root_pub_id: "dp-src-2",
          depth: 2,
          direction: :out
        )

      node_ids = Enum.map(drafts.nodes, &Map.get(&1, :doc_id))
      assert "dp-draft-target" in node_ids
      refute Enum.any?(drafts.nodes, fn n -> n[:broken_id] == "dp-draft-target" end)
    end

    test "the :sources filter applies to drafts plugin edges (published-path parity)" do
      publish!("dp-flt-target")

      # Root on the paper, direction :both, so ONE walk sees BOTH a core edge
      # (the linker's inbound `rel` — plugin_source nil; dangling under the
      # core :published lens since the paper is draft-only, but a dangling
      # inbound edge is still RECORDED in the edge list) and a plugin body
      # edge (the paper's outbound valueref — plugin_source "bulldocs").
      _paper =
        draft_only!("paper", "dp-flt-paper", %{
          "body" => [%{"type" => "valueref", "target" => "dp-flt-target"}]
        })

      _linker = draft_only!("linker", "dp-flt-src", %{"rel" => "dp-flt-paper"})

      unfiltered =
        Graph.traverse("dp-flt-paper",
          dataset: @dataset,
          perspective: :drafts,
          root_pub_id: "dp-flt-paper",
          depth: 3,
          direction: :both
        )

      unfiltered_pairs = Enum.map(unfiltered.edges, fn e -> {e.from_id, e.to_id} end)
      assert {"dp-flt-src", "dp-flt-paper"} in unfiltered_pairs
      assert {"dp-flt-paper", "dp-flt-target"} in unfiltered_pairs

      # Same root with sources: ["bulldocs"] — the paper's OWN plugin edge
      # survives; the linker's inbound core edge (plugin_source nil) is dropped
      # from the index before the walk.
      filtered =
        Graph.traverse("dp-flt-paper",
          dataset: @dataset,
          perspective: :drafts,
          root_pub_id: "dp-flt-paper",
          depth: 3,
          direction: :both,
          sources: ["bulldocs"]
        )

      filtered_pairs = Enum.map(filtered.edges, fn e -> {e.from_id, e.to_id} end)

      assert {"dp-flt-paper", "dp-flt-target"} in filtered_pairs,
             "sources: [\"bulldocs\"] must KEEP the plugin-sourced drafts edge"

      refute {"dp-flt-src", "dp-flt-paper"} in filtered_pairs,
             "sources: [\"bulldocs\"] must DROP core (nil-source) drafts edges"
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

  # ════════════════════════════════════════════════════════════════════════
  # dangling/1 vs the /v1/graph corpus opt-out
  #
  # /v1/graph's corpus derivation now passes `dangling: :skip` into
  # `extract_edges/2` because it discards the boolean. `Graph.dangling/1` — the
  # /v1/graph/dangling report — reads through the UNCHANGED default and must
  # keep naming exactly the same rows. It filters on `& &1.dangling`, so a
  # default flip would EMPTY the report silently; the second assertion below is
  # that mutation, run in-suite, proving the first assertion can actually fail.
  # ════════════════════════════════════════════════════════════════════════
  describe "dangling/1 (the /v1/graph/dangling report) is unaffected by the corpus opt-out" do
    setup do
      # One genuinely dangling reference (target never existed) and one live
      # reference, so the report has both a row to name and a row to exclude.
      publish!("gd-live-target")

      for {id, target} <- [{"gd-broken", "gd-nope"}, {"gd-ok", "gd-live-target"}] do
        {:ok, _} =
          Content.create_document(
            "linker",
            %{"_id" => id, "title" => id, "rel" => target},
            @dataset
          )

        {:ok, _} = Content.publish_document(id, "linker", @dataset)
      end

      :ok
    end

    test "names the dangling row and only that row" do
      rows = Graph.dangling(dataset: @dataset)

      assert Enum.any?(rows, fn r ->
               r.from_id == "gd-broken" and r.to_id == "gd-nope" and r.via_field == "rel"
             end),
             "the broken reference must still be reported: #{inspect(rows)}"

      refute Enum.any?(rows, &(&1.from_id == "gd-ok")),
             "a resolvable reference must never be reported dangling"
    end

    test "MUTATION: disabling dangling resolution on THIS route empties the report" do
      # The mutant — what a DEFAULT flip in extract_edges/2 would do to this
      # route. `dangling: nil` is falsy, so the filter drops every row and the
      # report goes silently blind. This RED is what makes the green above mean
      # something.
      assert Graph.dangling(dataset: @dataset, dangling: :skip) == []

      # …and the real route (no flag) is not the mutant.
      refute Graph.dangling(dataset: @dataset) == []
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

  # ════════════════════════════════════════════════════════════════════════
  # Airdrop-grants Layer-2 on the graph read path (ag-backlinks-grant-leak)
  #
  # A grant-derived caller (`grant_scoped: true` + a grant-bearing
  # CallerContext + workspace_id) must have its graph reads narrowed to the
  # UNION of its active grant scopes — the SAME `Scope.scope_to_grants` clause
  # that narrows `Content.Query`. This seals BOTH the HTTP backlinks cell (via
  # `resolve_doc` → `reverse_referencers`) AND the Studio PaneBuilder graph /
  # blast-radius pane (via `traverse` → `hydrate_nodes`), which already threads
  # `grant_scoped` but which Graph previously ignored. WITHOUT the flag every
  # read is byte-identical (the flag is the sole narrowing cause) — the whole
  # suite above proves the no-flag path unchanged; these cases isolate the flag.
  # ════════════════════════════════════════════════════════════════════════
  describe "grant-scoped graph reads (airdrop-grants Layer-2 — ag-backlinks-grant-leak)" do
    import Barkpark.TenancyFixtures
    import Barkpark.AccessFixtures

    alias Barkpark.Accounts
    alias Barkpark.Content.CallerContext

    @granted_ds "granted"
    @other_ds "other"
    @password "correct-horse-battery"

    setup do
      # Mirror the HTTP deny test's setup (grant_single_doc_deny_test.exs): the
      # DEFAULT workspace/project, so publish + edge-endpoint resolution resolve
      # the dataset cleanly (a fresh workspace's per-tenant dataset_id would need
      # scope threaded into every publish/add_edges call — the default scope is
      # the proven, minimal harness for the graph reads under test).
      {ws, project} = ensure_default_scope!()

      # `post` (grant-covered) lives in BOTH datasets; `note` (grant type is
      # `post`, so a note is OUT of the grant even in the granted dataset) lives
      # in the granted dataset — the type-ladder probe for the hydration seam.
      for ds <- [@granted_ds, @other_ds] do
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          ds
        )
      end

      Content.upsert_schema(
        %{"name" => "note", "title" => "Note", "visibility" => "public", "fields" => []},
        @granted_ds
      )

      seed = fn id, type, ds, title ->
        {:ok, _} =
          create_document_in!(ws, project, type, %{"_id" => id, "title" => title}, ds)

        {:ok, doc} = Content.publish_document(id, type, ds)
        doc
      end

      # in-scope (granted/post): target-in ← ref-in
      target_in = seed.("gr-target-in", "post", @granted_ds, "in-scope target")
      seed.("gr-ref-in", "post", @granted_ds, "in-scope referencer")

      Content.add_edges([%{from_id: "gr-ref-in", to_id: "gr-target-in", kind: "references"}],
        dataset: @granted_ds
      )

      # out-of-scope (other/post): target-out ← ref-out
      seed.("gr-target-out", "post", @other_ds, "out-of-scope target")
      seed.("gr-ref-out", "post", @other_ds, "out-of-scope referencer")

      Content.add_edges([%{from_id: "gr-ref-out", to_id: "gr-target-out", kind: "references"}],
        dataset: @other_ds
      )

      %{ws: ws, project: project, target_in: target_in}
    end

    # A CallerContext folding the grantee's ONE active read grant, scoped to
    # (project, dataset "granted", type "post") — the exact shape ResolveWorkspace
    # / AssignGrantScope fold in prod. The grantor is a live admin (AccessFixtures).
    defp grantee_ctx(ws, project) do
      email = "gr-grantee-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.register_user(%{email: email, password: @password})

      bind_grant!(ws, user, %{
        project_id: project.id,
        dataset: @granted_ds,
        type: "post",
        capabilities: ["read"]
      })

      ctx = CallerContext.from_user(user.id)
      # Non-vacuous: the grant actually loaded, else every read fails closed for
      # the wrong reason (and the byte-identical no-flag control would still pass).
      assert length(ctx.grants) == 1
      ctx
    end

    defp grant_opts(ctx, ws, ds, extra \\ []) do
      [dataset: ds, workspace_id: ws.id, caller_context: ctx, grant_scoped: true] ++ extra
    end

    test "resolve_doc grant-narrows: in-scope resolves, uncovered-dataset target → nil (fail-closed)",
         %{ws: ws, project: project} do
      ctx = grantee_ctx(ws, project)

      assert %Content.Document{doc_id: "gr-target-in"} =
               Graph.resolve_doc("gr-target-in", @granted_ds, grant_opts(ctx, ws, @granted_ds))

      # uncovered dataset: grant ladder ANDs `dataset == "granted"` → no row → nil
      assert Graph.resolve_doc("gr-target-out", @other_ds, grant_opts(ctx, ws, @other_ds)) == nil

      # byte-identical WITHOUT the flag (same ctx/workspace, grant_scoped dropped):
      # the out-of-grant doc resolves — the flag is the sole narrowing cause.
      assert %Content.Document{doc_id: "gr-target-out"} =
               Graph.resolve_doc("gr-target-out", @other_ds,
                 dataset: @other_ds,
                 workspace_id: ws.id,
                 caller_context: ctx
               )
    end

    test "reverse_referencers grant-narrows: in-scope returns its referencer, uncovered target → []",
         %{ws: ws, project: project} do
      ctx = grantee_ctx(ws, project)

      in_refs =
        "gr-target-in"
        |> Graph.reverse_referencers(grant_opts(ctx, ws, @granted_ds))
        |> Enum.map(& &1.from_doc_id)

      assert "gr-ref-in" in in_refs

      # THE sealed leak: an uncovered-dataset target resolves to nil under the
      # grant → reverse_referencers short-circuits to [] (never its referencers).
      assert Graph.reverse_referencers("gr-target-out", grant_opts(ctx, ws, @other_ds)) == []

      # byte-identical WITHOUT the flag: the out-of-grant referencer surfaces.
      out_refs =
        "gr-target-out"
        |> Graph.reverse_referencers(
          dataset: @other_ds,
          workspace_id: ws.id,
          caller_context: ctx
        )
        |> Enum.map(& &1.from_doc_id)

      assert "gr-ref-out" in out_refs
    end

    test "traverse grant-narrows hydration (Studio graph pane): an out-of-grant node is dropped with the flag, visible without it",
         %{ws: ws, project: project, target_in: target_in} do
      ctx = grantee_ctx(ws, project)

      # A `note` in the GRANTED dataset — same workspace/project/dataset as the
      # root, differing ONLY on the type ladder level (grant covers `post`). The
      # edge is intra-dataset so it materialises cleanly; the ONLY thing that can
      # hide the note from the grantee is the grant's `type == "post"` clause.
      {:ok, _} =
        create_document_in!(
          ws,
          project,
          "note",
          %{"_id" => "gr-note", "title" => "out-of-grant note"},
          @granted_ds
        )

      {:ok, _} = Content.publish_document("gr-note", "note", @granted_ds)

      Content.add_edges([%{from_id: "gr-target-in", to_id: "gr-note", kind: "references"}],
        dataset: @granted_ds
      )

      base = [dataset: @granted_ds, workspace_id: ws.id, depth: 2, direction: :out]

      node_ids = fn opts ->
        target_in.id |> Graph.traverse(opts) |> Map.fetch!(:nodes) |> Enum.map(& &1.doc_id)
      end

      grant_ids = node_ids.([caller_context: ctx, grant_scoped: true] ++ base)
      assert "gr-target-in" in grant_ids
      refute "gr-note" in grant_ids, "grant covers type post only — the note must not hydrate"

      # byte-identical WITHOUT the flag: the out-of-grant note hydrates.
      plain_ids = node_ids.([caller_context: ctx] ++ base)
      assert "gr-note" in plain_ids
    end

    test "fail-closed: grant_scoped with NO covering grant (nil caller_context) yields nil / []",
         %{ws: ws} do
      # A grant-derived read that carries the flag but no grant context must NEVER
      # fall through to the whole workspace — resolve_doc → nil, backlinks → [].
      opts = [dataset: @granted_ds, workspace_id: ws.id, grant_scoped: true]

      assert Graph.resolve_doc("gr-target-in", @granted_ds, opts) == nil
      assert Graph.reverse_referencers("gr-target-in", opts) == []
    end
  end
end
