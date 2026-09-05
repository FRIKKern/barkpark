defmodule BarkparkWeb.SynonymsDeleteNilWorkspaceTest do
  @moduledoc """
  The WRITE-side twin of the read fail-open PR #14349 closed, plus the guard
  that kept it inert.

  `Barkpark.Search.Synonyms.delete/4` authorizes through
  `workspace_deletable?/2`. Its `nil`-caller clause used to read

      defp workspace_deletable?(_row, nil), do: true

  so an unresolved-tenant caller could delete ANY row matching (surface, scope)
  — including a sibling workspace's. It was inert only because BOTH HTTP delete
  doors refuse a nil-workspace token BEFORE `delete/4` runs (the D58/D71
  `token_workspace_id(conn)` guard in `SearchController.delete_search_synonym/2`
  and `V1.MediaController.delete_search_synonym/2`). A guard in another module
  is one refactor away from moving, so this file pins BOTH halves:

    * "the nil arm is fail-closed" — the function boundary itself, no HTTP.
    * "the D58/D71 reachability guard" — both doors, asserting the TARGET ROW
      SURVIVES, not merely that a status code came back. A surviving row is the
      post-condition that says `delete/4` never destroyed anything.

  MUTATION-PROOF (fail-before).

    * Restore `defp workspace_deletable?(_row, nil), do: true` in
      `api/lib/barkpark/search/synonyms.ex` and the two "nil-workspace caller
      cannot delete a workspace-owned row" tests go RED: `delete/4` answers `:ok`
      and the tenant's row is gone. Re-narrowing greens them. The
      legacy/global (NULL-workspace) tests stay GREEN in both states — the
      narrowing removes cross-tenant reach, not the single-tenant corpus.
    * Delete the `token_workspace_id -> nil_workspace_write_error` clause from
      either controller's `delete_search_synonym/2` and that surface's door test
      goes RED: the nil-workspace token is masked to Default by
      `AssignDefaultScope`, answers 200, and the seeded legacy/global row is
      destroyed. Restoring the guard greens it.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Search.Synonym
  alias Barkpark.Search.Synonyms

  @ds "production"

  setup do
    # A Default Workspace must exist: without it the nil-workspace token would
    # fail to mask at all, and the door tests would pass for the wrong reason.
    {default_ws, _project} = ensure_default_scope!()
    ws_a = create_workspace!()
    ws_b = create_workspace!()
    {:ok, default_ws: default_ws, ws_a: ws_a, ws_b: ws_b}
  end

  defp seed!(surface, workspace_id, from) do
    {:ok, row} =
      %Synonym{}
      |> Synonym.changeset(%{
        surface: surface,
        scope: @ds,
        from_query: from,
        to_query: from <> "-to",
        kind: "one_way",
        source: "manual",
        workspace_id: workspace_id
      })
      |> Repo.insert()

    row
  end

  # A genuinely nil-workspace (legacy/global) admin token. `Auth.create_token`
  # binds an omitted workspace_id to Default post-backfill, so the legacy-null
  # token this file needs only exists via a direct changeset insert.
  defp nil_workspace_admin_token! do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "nil-ws-synonym-admin",
        dataset: @ds,
        permissions: ["read", "write", "admin"],
        workspace_id: nil
      })
      |> Repo.insert()

    raw
  end

  defp conn_for(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  describe "the nil arm of workspace_deletable?/2 is fail-closed" do
    test "documents: a nil-workspace caller cannot delete a workspace-owned row",
         %{ws_a: ws_a} do
      row = seed!("documents", ws_a.id, "nil-arm-doc-tenant")

      assert {:error, :not_found} = Synonyms.delete(row.id, "documents", @ds, nil)

      assert Repo.get(Synonym, row.id),
             "an unscoped (nil workspace_id) caller destroyed a tenant's synonym row"
    end

    test "media: a nil-workspace caller cannot delete a workspace-owned row",
         %{ws_b: ws_b} do
      row = seed!("media", ws_b.id, "nil-arm-med-tenant")

      assert {:error, :not_found} = Synonyms.delete(row.id, "media", @ds, nil)

      assert Repo.get(Synonym, row.id),
             "an unscoped (nil workspace_id) caller destroyed a tenant's synonym row"
    end

    test "a nil-workspace caller still deletes a legacy/global (NULL-workspace) row" do
      row = seed!("documents", nil, "nil-arm-global")

      # The single-tenant / pre-tenancy corpus: every row carries a NULL
      # workspace_id, so nil-deletes-nil must keep working. Fail-closed narrows
      # cross-tenant reach only.
      assert :ok = Synonyms.delete(row.id, "documents", @ds, nil)
      refute Repo.get(Synonym, row.id)
    end

    test "a workspace-bound caller is not over-blocked: own row and the shared layer",
         %{ws_a: ws_a} do
      own = seed!("documents", ws_a.id, "not-overblocked-own")
      shared = seed!("documents", nil, "not-overblocked-shared")

      assert :ok = Synonyms.delete(own.id, "documents", @ds, ws_a.id)
      assert :ok = Synonyms.delete(shared.id, "documents", @ds, ws_a.id)
      refute Repo.get(Synonym, own.id)
      refute Repo.get(Synonym, shared.id)
    end
  end

  describe "D58/D71 reachability guard — delete/4 is unreachable with a nil workspace" do
    test "documents door: nil-workspace token is refused and NO row is destroyed",
         %{ws_b: ws_b} do
      sibling = seed!("documents", ws_b.id, "door-doc-sibling")
      legacy = seed!("documents", nil, "door-doc-legacy")
      raw = nil_workspace_admin_token!()

      del_sibling =
        delete(conn_for(raw), "/v1/data/search/#{@ds}/synonyms/#{sibling.id}")

      assert json_response(del_sibling, 422)["error"]["code"] == "unprocessable"

      assert Repo.get(Synonym, sibling.id),
             "the documents delete door reached Synonyms.delete/4 with a nil workspace"

      # The legacy/global row is the discriminating target: it is deletable by
      # ANY resolved workspace, so if the D58/D71 guard ever moves the masked
      # Default caller destroys it and this assertion reds.
      del_legacy =
        delete(conn_for(raw), "/v1/data/search/#{@ds}/synonyms/#{legacy.id}")

      assert json_response(del_legacy, 422)["error"]["code"] == "unprocessable"

      assert Repo.get(Synonym, legacy.id),
             "the D58/D71 guard has moved: a nil-workspace token reached delete/4"
    end

    test "media door: nil-workspace token is refused and NO row is destroyed",
         %{ws_b: ws_b} do
      sibling = seed!("media", ws_b.id, "door-med-sibling")
      legacy = seed!("media", nil, "door-med-legacy")
      raw = nil_workspace_admin_token!()

      del_sibling =
        delete(conn_for(raw), "/v1/media/#{@ds}/search/synonyms/#{sibling.id}")

      assert json_response(del_sibling, 422)["error"]["code"] == "unprocessable"

      assert Repo.get(Synonym, sibling.id),
             "the media delete door reached Synonyms.delete/4 with a nil workspace"

      del_legacy =
        delete(conn_for(raw), "/v1/media/#{@ds}/search/synonyms/#{legacy.id}")

      assert json_response(del_legacy, 422)["error"]["code"] == "unprocessable"

      assert Repo.get(Synonym, legacy.id),
             "the D58/D71 guard has moved: a nil-workspace token reached delete/4"
    end
  end
end
