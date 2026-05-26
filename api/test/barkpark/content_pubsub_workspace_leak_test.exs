defmodule Barkpark.ContentPubsubWorkspaceLeakTest do
  @moduledoc """
  barkpark-n56v (P0) + barkpark-rwva (P1): per-doc PubSub topics MUST be
  workspace-scoped, or a write in workspace B leaks live deltas to workspace A's
  subscribers.

  Two flaws, one topic family:

    * P0 (n56v) — `paper_topic/3`. Paper slugs are PER-WORKSPACE, so A's
      `intro` and B's `intro` are distinct papers. The pre-fix topic
      `doc:<dataset>:paper:<slug>` had NO workspace component, so both papers
      collapsed onto ONE topic; B's `broadcast_paper_block` /
      `broadcast_paper_update` reached A's public viewer and patched B's private
      body into the public page.

    * P1 (rwva) — `doc_topic/4`. The pre-fix `doc:<dataset>:<type>:<pubid>`
      topic had the same flaw for ordinary documents; an editor in A could
      receive B's `{:doc_updated,…}` for a colliding `(type, pubid)`.

  The LEAK GATE here both proves the fix (A receives NOTHING from B) AND proves
  the gate fails against the pre-fix shared topic (A WOULD receive B's frame on
  the workspace-less topic). The SAME-TENANT tests prove the fix doesn't break
  legitimate live updates, and the NULL-workspace test proves the nil → Default
  normalization agrees on both sides.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Tenancy}

  @dataset Content.paper_default_dataset()
  @paper_type Content.paper_type()
  @slug "intro"

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  defp blocks(text) do
    [
      %{"id" => "h-1", "type" => "heading", "text" => "Title"},
      %{
        "id" => "b-1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    ]
  end

  defp append_op(id, text) do
    %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    }
  end

  setup do
    seed_paper_schema!()

    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "alpha", name: "Alpha"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "bravo", name: "Bravo"})

    # Each workspace owns a paper with the SAME slug — the per-workspace slug
    # collision that the workspace-less topic conflated.
    {:ok, paper_a} =
      Content.upsert_paper(%{
        slug: @slug,
        dataset: @dataset,
        workspace_id: ws_a.id,
        blocks: blocks("Alpha body")
      })

    {:ok, paper_b} =
      Content.upsert_paper(%{
        slug: @slug,
        dataset: @dataset,
        workspace_id: ws_b.id,
        blocks: blocks("Bravo body")
      })

    # Distinct rows, distinct tenants — the precondition for the leak.
    assert paper_a.id != paper_b.id
    assert paper_a.workspace_id == ws_a.id
    assert paper_b.workspace_id == ws_b.id

    %{ws_a: ws_a, ws_b: ws_b}
  end

  describe "LEAK GATE — paper_topic (barkpark-n56v, P0)" do
    test "A's subscriber receives NOTHING from B's paper broadcasts", %{ws_a: ws_a, ws_b: ws_b} do
      # Subscribe to workspace A's paper topic (what PaperLive does after
      # get_public_paper resolves A's row).
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(@slug, ws_a.id))

      # Trigger workspace B's own broadcasts.
      {:ok, _} =
        Content.apply_paper_block_op(@slug, append_op("b-leak", "B secret"), @dataset,
          workspace_id: ws_b.id
        )

      {:ok, _} =
        Content.upsert_paper(%{
          slug: @slug,
          dataset: @dataset,
          workspace_id: ws_b.id,
          blocks: blocks("B updated body")
        })

      # A hears NEITHER B's block delta NOR B's paper update.
      refute_receive {:paper_block, _}, 300
      refute_receive {:paper_updated, _}, 300
    end

    test "PROOF the gate fails against the pre-fix workspace-less topic", %{ws_b: ws_b} do
      # Reconstruct the PRE-FIX topic shape `doc:<dataset>:paper:<slug>` (no
      # workspace component). Subscribe to it the way PaperLive used to.
      prefix_topic = "doc:#{@dataset}:#{@paper_type}:#{@slug}"
      Phoenix.PubSub.subscribe(Barkpark.PubSub, prefix_topic)

      # Mirror what the OLD broadcaster did: broadcast on the same
      # workspace-less topic (this is exactly broadcast_paper_block's pre-fix
      # behaviour). Because A and B both collapsed onto this ONE topic, A WOULD
      # have received B's frame — the leak.
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        prefix_topic,
        {:paper_block, %{op_kind: "append-block", block_id: "b-leak", fragment_html: "B secret"}}
      )

      # Confirms the leak is real on the old topic — the gate above is
      # meaningful BECAUSE this one receives.
      assert_receive {:paper_block, %{fragment_html: "B secret"}}, 500

      # And the new workspace-scoped topic for B is DISTINCT from this one, so
      # the real broadcaster no longer hits the workspace-less topic at all.
      refute Content.paper_topic(@slug, ws_b.id) == prefix_topic
    end
  end

  describe "SAME-TENANT live updates still work" do
    test "A's own paper update + block delta reach A's subscriber", %{ws_a: ws_a} do
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(@slug, ws_a.id))

      {:ok, _} =
        Content.apply_paper_block_op(@slug, append_op("a-own", "A streamed"), @dataset,
          workspace_id: ws_a.id
        )

      assert_receive {:paper_block, %{fragment_html: frag}}, 1_000
      assert frag =~ "A streamed"

      {:ok, _} =
        Content.upsert_paper(%{
          slug: @slug,
          dataset: @dataset,
          workspace_id: ws_a.id,
          blocks: blocks("A new body")
        })

      assert_receive {:paper_updated, %{slug: @slug}}, 1_000
    end

    test "doc_topic (barkpark-rwva): A's own doc update reaches A, B's does not", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Posts", "visibility" => "public", "fields" => []},
          @dataset
        )

      # Two workspaces each own a doc with the SAME id+type (the per-workspace
      # collision the workspace-less doc_topic conflated).
      doc_id = "shared-post"

      {:ok, _doc_a} =
        Content.create_document("post", %{"_id" => doc_id, "title" => "A"}, @dataset,
          workspace_id: ws_a.id
        )

      {:ok, _doc_b} =
        Content.create_document("post", %{"_id" => doc_id, "title" => "B"}, @dataset,
          workspace_id: ws_b.id
        )

      # Subscribe the way StudioLive does — current_workspace.id (A here).
      Phoenix.PubSub.subscribe(
        Barkpark.PubSub,
        Content.doc_topic(doc_id, "post", ws_a.id, @dataset)
      )

      # B edits B's colliding doc → A hears NOTHING.
      {:ok, _} =
        Content.upsert_document("post", %{"doc_id" => doc_id, "title" => "B edit"}, @dataset,
          workspace_id: ws_b.id
        )

      refute_receive {:doc_updated, _}, 300

      # A edits A's own doc → A DOES hear it (same-tenant live update intact).
      {:ok, _} =
        Content.upsert_document("post", %{"doc_id" => doc_id, "title" => "A edit"}, @dataset,
          workspace_id: ws_a.id
        )

      assert_receive {:doc_updated, %{type: "post", doc: %{title: "A edit"}}}, 1_000
    end
  end

  describe "FAN-OUT GATE — document-list topic (barkpark-fe2k)" do
    # The SSE listen stream + StudioLive list view used to subscribe the BARE
    # `documents:#{dataset}` topic, which every co-dataset tenant broadcasts to
    # — so A's stream received (then discarded via forward_event?/3 /
    # rebuild_panes scope_opts) every B mutation. The fix subscribes the
    # workspace-scoped `documents:ws:#{ws}:#{dataset}` topic instead. These
    # tests prove, at the TOPIC level: (1) A still gets its OWN events
    # (self-delivery intact), (2) A no longer gets B's events (fan-out gone),
    # and (3) the old bare topic WOULD have fanned B's event out (the regression
    # we removed).
    @list_dataset "shared-list"

    setup do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Posts", "visibility" => "public", "fields" => []},
          @list_dataset
        )

      :ok
    end

    test "A's ws-scoped list subscriber gets A's OWN event but NOT B's", %{
      ws_a: ws_a,
      ws_b: ws_b
    } do
      # Subscribe exactly as the fixed SSE controller / StudioLive list view do
      # when a workspace is resolved.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws_a.id}:#{@list_dataset}")

      # B writes a co-dataset doc → A's ws-scoped subscriber hears NOTHING
      # (the bare-topic fan-out is gone; B never broadcasts to A's topic).
      {:ok, _doc_b} =
        Content.create_document("post", %{"_id" => "b-doc", "title" => "B"}, @list_dataset,
          workspace_id: ws_b.id
        )

      refute_receive {:document_changed, _}, 300

      # A writes its OWN doc → A's ws-scoped subscriber DOES hear it
      # (self-delivery on the additive ws-scoped topic is intact).
      {:ok, _doc_a} =
        Content.create_document("post", %{"_id" => "a-doc", "title" => "A"}, @list_dataset,
          workspace_id: ws_a.id
        )

      assert_receive {:document_changed, %{workspace_id: wid, doc_id: "drafts.a-doc"}}, 1_000
      assert wid == ws_a.id
    end

    test "PROOF the old bare topic WOULD have fanned B's event out to A", %{ws_b: ws_b} do
      # Reconstruct the pre-fix subscribe: the bare `documents:#{dataset}` topic
      # with NO workspace component. content.ex still broadcasts here additively,
      # so a bare subscriber receives EVERY co-dataset tenant's event — the
      # wasteful fan-out the fix removes.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@list_dataset}")

      {:ok, _doc_b} =
        Content.create_document("post", %{"_id" => "bare-b", "title" => "B"}, @list_dataset,
          workspace_id: ws_b.id
        )

      # The bare topic receives B's event — proving the fan-out is real and the
      # ws-scoped gate above is meaningful.
      assert_receive {:document_changed, %{doc_id: "drafts.bare-b", workspace_id: wid}}, 1_000
      assert wid == ws_b.id
    end

    test "nil-workspace (Default/flat) write still lands on the bare topic" do
      # The back-compat path: a write without an explicit workspace (Default
      # fallback) — the nil-scope listener keeps the bare subscribe, and
      # content.ex always fires the bare topic, so self-delivery holds there too.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@list_dataset}")

      {:ok, _doc} =
        Content.create_document("post", %{"_id" => "default-doc", "title" => "D"}, @list_dataset)

      assert_receive {:document_changed, %{doc_id: "drafts.default-doc"}}, 1_000
    end
  end

  describe "NULL-workspace (legacy) normalization agrees on both sides" do
    test "a Default/legacy paper's update reaches its public viewer" do
      # The public viewer (PaperLive) resolves the paper through
      # get_public_paper — which scopes to the seeded Default workspace — and
      # subscribes with that resolved row's workspace_id.
      default_ws = Tenancy.get_default_workspace()
      assert %{id: _} = default_ws

      legacy_slug = "legacy"

      # A legacy paper written WITHOUT an explicit workspace lands in the Default
      # workspace (upsert_paper's Default fallback). Its public viewer subscribes
      # with paper.workspace_id (== Default) — and broadcast_paper_* stamps the
      # same. To prove the normalization meeting point, subscribe with the
      # SUBSCRIBER's view: nil normalized to Default, which paper_topic resolves.
      {:ok, paper} =
        Content.upsert_paper(%{slug: legacy_slug, dataset: @dataset, blocks: blocks("legacy")})

      assert paper.workspace_id == default_ws.id

      public = Content.get_public_paper(legacy_slug)
      assert public.workspace_id == default_ws.id

      # Subscriber resolves nil → Default (the legacy/normalization path) and the
      # broadcaster stamps the Default ws → both land on the SAME topic.
      assert Content.paper_topic(legacy_slug, nil) ==
               Content.paper_topic(legacy_slug, default_ws.id)

      Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(legacy_slug, nil))

      {:ok, _} =
        Content.upsert_paper(%{
          slug: legacy_slug,
          dataset: @dataset,
          blocks: blocks("legacy updated")
        })

      assert_receive {:paper_updated, %{slug: ^legacy_slug}}, 1_000
    end
  end
end
