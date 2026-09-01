defmodule Barkpark.Media.Storage.ShareScopeTest do
  @moduledoc """
  P0 cross-workspace share-link WRITE leak (barkpark-ukzs).

  `Share.create/3` and `Share.revoke/3` enable / rotate / disable the
  `content.shareLink.{token,enabled,expiresAt}` on a `mediaCollection`
  document. Before the fix both functions called the inner
  `Collections.get(collection_id, dataset)` with NO scope opts — defaulting to
  `[]` → an unscoped (global + Default-project) read. So a workspace-B writer
  could resolve workspace-A's collection whenever the two shared the
  `dataset` STRING + the collection `doc_id`, then the follow-on
  `Content.upsert_document` write landed on A's row:

    * `Share.create` minted/rotated A's `shareLink.token` and RETURNED that
      token to the wrong (B) tenant.
    * `Share.revoke` flipped A's `shareLink.enabled` to false.

  The controller's `share/2` and `revoke_share/2` actions also dropped
  `scope_opts(conn)` — the sibling reads (`Collections.get`,
  `add_member`/`remove_member`) thread it. The fix threads the
  caller's scope end-to-end: controller → `Share.create/revoke` →
  `Collections.get(collection_id, dataset, opts)`, which already applies the
  scope envelope (the proven sibling path).

  Three guarantees are proved here:

    1. LEAK GATE — a `Share.create` / `Share.revoke` issued in workspace B's
       scope must NOT mint/rotate/revoke workspace A's collection share link
       even though both share the `production` dataset STRING + the same
       collection id (→ `:not_found`, A's row untouched). Confirmed to FAIL
       against the pre-fix unscoped read — see the leak-gate note.
    2. RIGHT-TENANT TOKEN — an in-scope `Share.create` returns a token, and
       that token resolves ONLY against the caller's own collection (never the
       other tenant's same-id collection).
    3. IN-SCOPE — `Share.create` / `Share.revoke` on the caller's own
       collection work (token minted; enabled flipped on then off).
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.Share

  @collection_type "mediaCollection"
  # Deliberately the SAME dataset STRING across workspaces — isolation must
  # come from workspace_id, not the dataset leaf.
  @dataset "production"

  # Create a `mediaCollection` document STAMPED with the given workspace/project
  # scope, carrying an explicit `doc_id` so two workspaces can share the SAME
  # collection id (the leak's precondition). Returns the stored draft doc_id,
  # which is what `Share.create/revoke` + the controller URL `:id` carry.
  defp create_collection!(workspace, project, doc_id, title) do
    {:ok, doc} =
      Content.create_document(
        @collection_type,
        %{"doc_id" => doc_id, "title" => title, "content" => %{"kind" => "folder"}},
        @dataset,
        workspace_id: workspace.id,
        project_id: project.id
      )

    doc.doc_id
  end

  # Re-read a collection row by doc_id WITHOUT any scope filter (raw Repo) so a
  # test can inspect the actual persisted shareLink of a specific tenant's row.
  defp raw_collection(doc_id, workspace_id) do
    import Ecto.Query

    Document
    |> where([d], d.doc_id == ^doc_id and d.type == ^@collection_type)
    |> where([d], d.dataset == ^@dataset and d.workspace_id == ^workspace_id)
    |> Barkpark.Repo.one()
  end

  defp share_link(%Document{content: content}) when is_map(content),
    do: Map.get(content, "shareLink")

  defp share_link(_), do: nil

  describe "LEAK GATE — share-link writes isolated across workspaces" do
    # PRE-FIX CONFIRMATION (proven by reverting ONLY the controller→Share scope
    # threading + the inner Collections.get opts + the write_opts/1 upsert
    # scope, then re-running): the pre-fix `Share.create/revoke` called
    # `Collections.get(collection_id, dataset)` with opts defaulted to [] →
    # `Scope.scope_to_workspace_or_global(nil, nil)` = the global + DEFAULT-
    # project read. Victim A's collection lives in the DEFAULT workspace —
    # exactly what that unscoped read resolves. So a workspace-B writer's
    # `Share.create` resolved A's Default collection and the follow-on upsert
    # minted `shareLink.token` ON A's ROW (and returned that token to B);
    # `Share.revoke` flipped A's `shareLink.enabled` to false. AGAINST PRE-FIX
    # the `refute share_link(...)` / `assert "enabled" => true` checks below
    # FAIL — B mutated A's Default row. With the fix B's scoped `Collections.get`
    # filters by workspace_id=B and A's Default row is invisible → `:not_found`,
    # A untouched. Leak confirmed-fails-against-prefix.
    test "Share.create scoped to workspace B never mints a token on the Default workspace's same-id collection" do
      {default_ws, default_proj} = ensure_default_scope!()
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      shared_id = "col-#{System.unique_integer([:positive])}"

      # Victim A's collection lives in the DEFAULT workspace — the exact row the
      # pre-fix unscoped read resolves. B never owns this id.
      a_doc_id =
        create_collection!(default_ws, default_proj, shared_id, "Default-workspace collection")

      # B issues create scoped to ITS OWN workspace for A's collection id.
      result =
        Share.create(a_doc_id, @dataset, workspace_id: ws_b.id, project_id: proj_b.id)

      assert result == {:error, :not_found},
             "CROSS-WORKSPACE SHARE LEAK: workspace B minted a share token on " <>
               "the Default workspace's collection (#{inspect(result)})"

      # A's (Default) row must carry NO shareLink — B's write never touched it.
      # This is the line that FAILS against pre-fix (B's unscoped upsert minted
      # a token on A's Default row).
      refute share_link(raw_collection(a_doc_id, default_ws.id)),
             "CROSS-WORKSPACE SHARE LEAK: the Default workspace's collection gained " <>
               "a shareLink from a workspace-B Share.create"
    end

    test "Share.revoke scoped to workspace B never disables the Default workspace's active share link" do
      {default_ws, default_proj} = ensure_default_scope!()
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      shared_id = "col-#{System.unique_integer([:positive])}"

      a_doc_id =
        create_collection!(default_ws, default_proj, shared_id, "Default-workspace collection")

      # A enables its own share link (in A's / Default scope).
      assert {:ok, %{token: a_token}} =
               Share.create(a_doc_id, @dataset,
                 workspace_id: default_ws.id,
                 project_id: default_proj.id
               )

      assert is_binary(a_token)
      assert %{"enabled" => true} = share_link(raw_collection(a_doc_id, default_ws.id))

      # B attempts to revoke A's collection id, scoped to B.
      result =
        Share.revoke(a_doc_id, @dataset, workspace_id: ws_b.id, project_id: proj_b.id)

      assert result == {:error, :not_found},
             "CROSS-WORKSPACE SHARE LEAK: workspace B revoked the Default workspace's " <>
               "share link (#{inspect(result)})"

      # A's share link must still be enabled — B's revoke was a no-op on A. This
      # is the line that FAILS against pre-fix (B's unscoped upsert flipped A's
      # Default row's `enabled` to false).
      default_link = share_link(raw_collection(a_doc_id, default_ws.id))

      assert match?(%{"enabled" => true}, default_link),
             "CROSS-WORKSPACE SHARE LEAK: the Default workspace's share link was " <>
               "disabled by a workspace-B Share.revoke (#{inspect(default_link)})"
    end
  end

  describe "RIGHT-TENANT TOKEN — minted token resolves only against the caller's collection" do
    test "Share.create in A's scope mints a token that resolves to A's collection, not B's same-id collection" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      shared_id = "col-#{System.unique_integer([:positive])}"

      a_doc_id = create_collection!(ws_a, proj_a, shared_id, "Workspace A collection")
      _b_doc_id = create_collection!(ws_b, proj_b, shared_id, "Workspace B collection")

      assert {:ok, %{token: a_token}} =
               Share.create(a_doc_id, @dataset, workspace_id: ws_a.id, project_id: proj_a.id)

      assert is_binary(a_token)

      # A's token landed on A's row…
      assert %{"token" => ^a_token, "enabled" => true} =
               share_link(raw_collection(a_doc_id, ws_a.id))

      # …and NOT on B's same-id collection (no leak the other way).
      assert is_nil(share_link(raw_collection(a_doc_id, ws_b.id))),
             "workspace B's same-id collection unexpectedly carries A's minted token"

      # The token resolves to A's collection through the (token-gated) public
      # read half — proving the right tenant got the live token.
      assert {:ok, %Document{} = resolved} = Share.resolve(a_token, @dataset)
      assert resolved.workspace_id == ws_a.id
      assert resolved.title == "Workspace A collection"
    end
  end

  describe "IN-SCOPE — share create/revoke work on the caller's own collection" do
    test "create then revoke flips enabled true → false on the caller's own collection" do
      ws = create_workspace!()
      proj = create_project!(ws)

      doc_id =
        create_collection!(
          ws,
          proj,
          "col-#{System.unique_integer([:positive])}",
          "Own collection"
        )

      assert {:ok, %{token: token, shareUrl: share_url}} =
               Share.create(doc_id, @dataset, workspace_id: ws.id, project_id: proj.id)

      assert is_binary(token)
      assert share_url =~ token
      assert %{"enabled" => true, "token" => ^token} = share_link(raw_collection(doc_id, ws.id))

      assert {:ok, %Document{}} =
               Share.revoke(doc_id, @dataset, workspace_id: ws.id, project_id: proj.id)

      assert %{"enabled" => false} = share_link(raw_collection(doc_id, ws.id))
    end
  end
end
