defmodule BarkparkWeb.Contract.ListenWorkspaceScopeTest do
  @moduledoc """
  Cross-tenant isolation contract for the SSE listen stream (barkpark-dm8l).

  The legacy `listen_test.exs` only exercises the 2-arg / nil-workspace
  `replay_since` — the UNFILTERED path. This module proves the tenant
  boundary that `ListenController` grew: the workspace-scoped
  `replay_since/3` filter and the live `forward_event?/2` drop. Both must
  isolate two workspaces that share ONE dataset string.

  It also proves the DELETE TOMBSTONE contract: a workspace-scoped listener
  MUST still learn about deletes (live + replay), even though a delete's
  `documents` row is gone. The scope filter reads the event/msg's own
  denormalised `workspace_id`, not a join/existence-check against the
  (now-absent) document row — so tombstones survive and reach the right tenant
  without leaking to another.

  Assertions name WHICH workspace's event survives, never a bare count —
  a count can pass while the wrong row leaks.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias BarkparkWeb.ListenController

  @dataset "shared"

  setup do
    # Same dataset STRING across both workspaces — isolation must come from
    # workspace_id, not the dataset leaf.
    Barkpark.Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    ws_a = create_workspace!()
    proj_a = create_project!(ws_a)
    ws_b = create_workspace!()
    proj_b = create_project!(ws_b)

    # One document per workspace, distinct ids, SAME dataset string.
    {:ok, doc_a} =
      create_document_in!(ws_a, proj_a, "post", %{"doc_id" => "alpha", "title" => "A"}, @dataset)

    {:ok, doc_b} =
      create_document_in!(ws_b, proj_b, "post", %{"doc_id" => "beta", "title" => "B"}, @dataset)

    %{ws_a: ws_a, ws_b: ws_b, doc_a: doc_a, doc_b: doc_b}
  end

  describe "replay_since/3 — workspace-scoped resume" do
    test "returns ONLY workspace A's event when scoped to A", %{
      ws_a: ws_a,
      doc_a: doc_a,
      doc_b: doc_b
    } do
      events = ListenController.replay_since(@dataset, 0, ws_a.id)
      doc_ids = Enum.map(events, & &1.doc_id)

      # WHICH workspace — A's doc present, B's doc absent.
      assert doc_a.doc_id in doc_ids,
             "expected A's event (#{doc_a.doc_id}) under A's scope, got #{inspect(doc_ids)}"

      refute doc_b.doc_id in doc_ids,
             "CROSS-TENANT LEAK: B's event (#{doc_b.doc_id}) surfaced under A's scope"

      # And the surviving row genuinely is A's, not a same-id collision.
      surviving = Enum.find(events, &(&1.doc_id == doc_a.doc_id))
      assert surviving
      assert surviving.dataset == @dataset
    end

    test "returns ONLY workspace B's event when scoped to B", %{
      ws_b: ws_b,
      doc_a: doc_a,
      doc_b: doc_b
    } do
      doc_ids = ListenController.replay_since(@dataset, 0, ws_b.id) |> Enum.map(& &1.doc_id)

      assert doc_b.doc_id in doc_ids

      refute doc_a.doc_id in doc_ids,
             "CROSS-TENANT LEAK: A's event (#{doc_a.doc_id}) surfaced under B's scope"
    end

    test "nil scope (back-compat) returns BOTH workspaces' events", %{
      doc_a: doc_a,
      doc_b: doc_b
    } do
      doc_ids = ListenController.replay_since(@dataset, 0) |> Enum.map(& &1.doc_id)

      assert doc_a.doc_id in doc_ids
      assert doc_b.doc_id in doc_ids
    end
  end

  describe "forward_event?/2 — live stream drop gate" do
    # Live broadcast msg shape (as tap_broadcast stamps it): the denormalised
    # workspace_id is the tenant discriminator, present on every event incl.
    # deletes (whose documents row is gone).
    defp msg(doc, ws), do: %{doc_id: doc.doc_id, workspace_id: ws.id, mutation: "update"}

    test "drops B's doc, forwards A's doc, for an A-scoped listener", %{
      ws_a: ws_a,
      ws_b: ws_b,
      doc_a: doc_a,
      doc_b: doc_b
    } do
      assert ListenController.forward_event?(msg(doc_a, ws_a), ws_a.id) == true,
             "A's own doc must be forwarded to an A-scoped listener"

      refute ListenController.forward_event?(msg(doc_b, ws_b), ws_a.id),
             "CROSS-TENANT LEAK: B's doc forwarded to an A-scoped listener"
    end

    test "symmetric: drops A's doc, forwards B's doc, for a B-scoped listener", %{
      ws_a: ws_a,
      ws_b: ws_b,
      doc_a: doc_a,
      doc_b: doc_b
    } do
      assert ListenController.forward_event?(msg(doc_b, ws_b), ws_b.id) == true
      refute ListenController.forward_event?(msg(doc_a, ws_a), ws_b.id)
    end

    test "nil scope forwards everything (unscoped back-compat listener)", %{
      ws_a: ws_a,
      ws_b: ws_b,
      doc_a: doc_a,
      doc_b: doc_b
    } do
      assert ListenController.forward_event?(msg(doc_a, ws_a), nil) == true
      assert ListenController.forward_event?(msg(doc_b, ws_b), nil) == true
    end
  end

  describe "delete tombstone — live forward_event?/2" do
    test "A's delete tombstone is forwarded to an A-scoped listener even after the row is gone",
         %{ws_a: ws_a, doc_a: doc_a} do
      # Delete the doc: its `documents` row is now GONE. The OLD existence-check
      # gate would drop the tombstone here; the denormalised workspace_id gate
      # forwards it.
      {:ok, _} =
        Barkpark.Content.delete_document(doc_a.doc_id, "post", @dataset, workspace_id: ws_a.id)

      delete_msg = %{doc_id: doc_a.doc_id, workspace_id: ws_a.id, mutation: "delete"}

      assert ListenController.forward_event?(delete_msg, ws_a.id) == true,
             "delete tombstone must reach the owning-workspace listener (cache must learn of the delete)"
    end

    test "another workspace's delete tombstone is NOT forwarded to an A-scoped listener",
         %{ws_a: ws_a, ws_b: ws_b, doc_b: doc_b} do
      {:ok, _} =
        Barkpark.Content.delete_document(doc_b.doc_id, "post", @dataset, workspace_id: ws_b.id)

      delete_msg = %{doc_id: doc_b.doc_id, workspace_id: ws_b.id, mutation: "delete"}

      refute ListenController.forward_event?(delete_msg, ws_a.id),
             "CROSS-TENANT LEAK: B's delete tombstone forwarded to an A-scoped listener"
    end
  end

  describe "delete tombstone — replay_since/3 resume" do
    test "A's delete tombstone appears on an A-scoped replay after the row is gone", %{
      ws_a: ws_a,
      doc_a: doc_a
    } do
      {:ok, _} =
        Barkpark.Content.delete_document(doc_a.doc_id, "post", @dataset, workspace_id: ws_a.id)

      events = ListenController.replay_since(@dataset, 0, ws_a.id)

      # The delete event (tombstone) is present under A's scope. Under the old
      # INNER-JOIN this returned nothing for `alpha` — the join found no
      # surviving `documents` row, so BOTH the create and the delete vanished.
      assert Enum.any?(events, &(&1.doc_id == doc_a.doc_id and &1.mutation == "delete")),
             "expected A's delete tombstone on replay, got #{inspect(Enum.map(events, &{&1.doc_id, &1.mutation}))}"
    end

    test "another workspace's delete tombstone is NOT on an A-scoped replay", %{
      ws_a: ws_a,
      ws_b: ws_b,
      doc_b: doc_b
    } do
      {:ok, _} =
        Barkpark.Content.delete_document(doc_b.doc_id, "post", @dataset, workspace_id: ws_b.id)

      events = ListenController.replay_since(@dataset, 0, ws_a.id)

      refute Enum.any?(events, &(&1.doc_id == doc_b.doc_id)),
             "CROSS-TENANT LEAK: B's delete tombstone surfaced on an A-scoped replay"
    end
  end

  describe "Default-scoped listener vs another workspace's mutation" do
    test "Default workspace's stream does not forward another workspace's event", %{
      ws_b: ws_b
    } do
      {default_ws, default_proj} = ensure_default_scope!()

      {:ok, default_doc} =
        create_document_in!(
          default_ws,
          default_proj,
          "post",
          %{"doc_id" => "default-doc", "title" => "D"},
          @dataset
        )

      {:ok, b_doc} =
        create_document_in!(
          ws_b,
          create_project!(ws_b),
          "post",
          %{"doc_id" => "b-only", "title" => "B2"},
          @dataset
        )

      default_msg = %{doc_id: default_doc.doc_id, workspace_id: default_ws.id, mutation: "update"}
      b_msg = %{doc_id: b_doc.doc_id, workspace_id: ws_b.id, mutation: "update"}

      # The Default-scoped listener forwards its own event...
      assert ListenController.forward_event?(default_msg, default_ws.id) == true

      # ...but B's mutation, broadcast on the shared dataset topic, is dropped.
      refute ListenController.forward_event?(b_msg, default_ws.id),
             "CROSS-TENANT LEAK: another workspace's mutation reached the Default-scoped stream"

      # And the replay-resume path for the Default listener excludes B too.
      default_replay = ListenController.replay_since(@dataset, 0, default_ws.id)
      replay_ids = Enum.map(default_replay, & &1.doc_id)
      assert default_doc.doc_id in replay_ids
      refute b_doc.doc_id in replay_ids
    end
  end
end
