defmodule BarkparkWeb.SearchSettingsFailClosedTest do
  @moduledoc """
  D58/D71 — the flat admin search-settings WRITE must FAIL-CLOSED on a
  nil-workspace token, on BOTH surfaces (documents + media).

  D58 was decided in W5 but shipped fail-SOFT: the WRITE resolved its workspace
  via `workspace_id(conn)` = `conn.assigns.current_workspace`, which
  `AssignDefaultScope` has ALREADY masked from nil to the Default Workspace. So a
  genuinely nil-workspace admin token PUT returned 200 and SILENTLY attributed
  the config to Default (an operator footgun, VF7-proven on both surfaces).

  The fix reads the RAW pre-mask `conn.assigns.api_token.workspace_id` (assigned
  by `RequireToken`, BEFORE the mask) and returns 422 when nil, BEFORE any
  `SurfaceConfigs.upsert`. A workspace-bound admin token is unaffected — it still
  writes its OWN `(workspace_id, surface, scope)` row.

  Reproducing a nil-workspace token: `Auth.create_token` binds an omitted
  `workspace_id` to Default post-backfill, so ONLY a direct `Repo.insert` with an
  explicit `workspace_id: nil` yields the legacy-null token this net catches.

  RED before the fix: the nil-token PUT below returned 200 (writing Default)
  instead of 422.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Search.SurfaceConfig

  @ds "production"

  setup do
    # A Default Workspace must exist so the pre-fix path (masking nil → Default)
    # would have succeeded — that is exactly the 200-writing-Default footgun the
    # fail-closed guard replaces with a 422.
    {default_ws, _project} = ensure_default_scope!()
    {:ok, default_ws: default_ws}
  end

  # Mint an admin token straight through the schema changeset so `workspace_id`
  # can be forced to `nil` (create_token would bind it to Default).
  defp insert_admin_token!(attrs) do
    raw = "tok-" <> Ecto.UUID.generate()

    {:ok, _token} =
      %ApiToken{}
      |> ApiToken.changeset(
        Map.merge(
          %{
            token_hash: ApiToken.hash_token(raw),
            label: "settings-admin",
            dataset: @ds,
            permissions: ["read", "write", "admin"]
          },
          attrs
        )
      )
      |> Repo.insert()

    raw
  end

  defp put_settings(raw, path) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> put(path, %{"highlightFields" => ["title"]})
  end

  describe "documents surface — PUT /v1/data/search/:dataset/settings" do
    test "a nil-workspace admin token is refused 422 and writes NO row" do
      raw = insert_admin_token!(%{workspace_id: nil})

      conn = put_settings(raw, "/v1/data/search/#{@ds}/settings")

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"

      # fail-CLOSED: no Default/global row was silently written.
      refute Repo.get_by(SurfaceConfig, surface: "documents", scope: @ds)
    end

    test "a workspace-bound admin token writes its OWN row (200)" do
      bound_ws = create_workspace!()
      raw = insert_admin_token!(%{workspace_id: bound_ws.id})

      conn = put_settings(raw, "/v1/data/search/#{@ds}/settings")

      assert %{"result" => _} = json_response(conn, 200)

      row = Repo.get_by(SurfaceConfig, surface: "documents", scope: @ds)
      assert row.workspace_id == bound_ws.id
    end
  end

  describe "media surface — PUT /v1/media/:dataset/search/settings" do
    test "a nil-workspace admin token is refused 422 and writes NO row" do
      raw = insert_admin_token!(%{workspace_id: nil})

      conn = put_settings(raw, "/v1/media/#{@ds}/search/settings")

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"

      refute Repo.get_by(SurfaceConfig, surface: "media", scope: @ds)
    end

    test "a workspace-bound admin token writes its OWN row (200)" do
      bound_ws = create_workspace!()
      raw = insert_admin_token!(%{workspace_id: bound_ws.id})

      conn = put_settings(raw, "/v1/media/#{@ds}/search/settings")

      assert %{"result" => _} = json_response(conn, 200)

      row = Repo.get_by(SurfaceConfig, surface: "media", scope: @ds)
      assert row.workspace_id == bound_ws.id
    end
  end
end
