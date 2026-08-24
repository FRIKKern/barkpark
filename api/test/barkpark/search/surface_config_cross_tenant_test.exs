defmodule Barkpark.Search.SurfaceConfigCrossTenantTest do
  @moduledoc """
  Fail-before protective test for the LIVE cross-tenant search-surface-config
  bleed (charter D45/D49, Wave 5 Slice A).

  V1 of the wave PROVED by RUNNING that `search_surface_config` shared EXACTLY
  ONE physical `(surface, scope)` row across tenants: two workspaces both owning
  the universally-shared `"production"` dataset slug shared a single config row,
  so workspace A's admin `PUT …/search/production/settings` overwrote workspace
  B's config — spanning BOTH the documents surface (search_controller.ex) and the
  media surface (v1/media_controller.ex). The write route is `:require_admin`
  global-perm gated, so this is a global-admin cross-tenant overwrite.

  RED on origin/main: the controllers called `SurfaceConfigs.upsert(surface,
  scope, params)` (no workspace), and the flat route ran `[:api, :require_admin]`
  which stamps `current_workspace = Default` (or nil) for EVERY token — so both
  tokens wrote/read the SAME row and B saw A's value.

  GREEN after the fix: the runtime key became `(workspace_id, surface, scope)`
  and a bespoke `:flat_admin_api` pipeline derives the caller's OWN
  workspace from its admin token BEFORE `AssignDefaultScope`, so A's write and
  B's read land on DISTINCT physical rows.

  Both surfaces are asserted separately (they are different physical rows written
  by different controllers) per the task contract.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Search.SurfaceConfigs

  @scope "production"

  setup do
    # Two workspaces both owning the shared "production" scope — the exact bleed
    # shape. Each gets its OWN workspace-scoped admin token via the tenancy-aware
    # mint (create_token(..., ws.id)); a nil-workspace token would resolve to the
    # Default Workspace and could not distinguish the tenants (charter D49).
    ws_a = create_workspace!()
    ws_b = create_workspace!()

    {:ok, _} =
      Auth.create_token(token_a(), "bleed-a", @scope, ["read", "write", "admin"], ws_a.id)

    {:ok, _} =
      Auth.create_token(token_b(), "bleed-b", @scope, ["read", "write", "admin"], ws_b.id)

    # The workspace-agnostic global defaults the anonymous read path reads.
    SurfaceConfigs.seed_defaults!()

    on_exit(fn -> SurfaceConfigs.__reset_cache_for_test__() end)

    {:ok, ws_a: ws_a, ws_b: ws_b}
  end

  defp token_a, do: "bleed-token-a"
  defp token_b, do: "bleed-token-b"

  defp as(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "documents: workspace A's PUT does NOT change workspace B's config", %{conn: conn} do
    # B's baseline BEFORE A writes.
    before =
      conn
      |> as(token_b())
      |> get("/v1/data/search/#{@scope}/settings")
      |> json_response(200)

    assert before["result"]["zero_hit_strategy"] == "drop_tokens"

    # A overwrites its OWN documents config on the shared scope.
    a_resp =
      conn
      |> recycle()
      |> as(token_a())
      |> put("/v1/data/search/#{@scope}/settings", %{"zeroHitStrategy" => "typo_widen"})
      |> json_response(200)

    assert a_resp["result"]["zero_hit_strategy"] == "typo_widen"

    # B reads again — its config is UNCHANGED. On origin/main it returns
    # "typo_widen" (the shared row A just wrote) → this assertion FAILS → RED.
    after_b =
      conn
      |> recycle()
      |> as(token_b())
      |> get("/v1/data/search/#{@scope}/settings")
      |> json_response(200)

    assert after_b["result"]["zero_hit_strategy"] == "drop_tokens",
           "workspace B's documents search config was overwritten by workspace A (cross-tenant bleed)"
  end

  test "media: workspace A's PUT does NOT change workspace B's config", %{conn: conn} do
    before =
      conn
      |> as(token_b())
      |> get("/v1/media/#{@scope}/search/settings")
      |> json_response(200)

    assert before["result"]["zero_hit_strategy"] == "drop_tokens"

    a_resp =
      conn
      |> recycle()
      |> as(token_a())
      |> put("/v1/media/#{@scope}/search/settings", %{"zeroHitStrategy" => "typo_widen"})
      |> json_response(200)

    assert a_resp["result"]["zero_hit_strategy"] == "typo_widen"

    after_b =
      conn
      |> recycle()
      |> as(token_b())
      |> get("/v1/media/#{@scope}/search/settings")
      |> json_response(200)

    assert after_b["result"]["zero_hit_strategy"] == "drop_tokens",
           "workspace B's media search config was overwritten by workspace A (cross-tenant bleed)"
  end

  test "the two workspaces persist DISTINCT physical rows for the same (surface, scope)",
       %{conn: conn, ws_a: ws_a, ws_b: ws_b} do
    conn
    |> as(token_a())
    |> put("/v1/data/search/#{@scope}/settings", %{"zeroHitStrategy" => "typo_widen"})
    |> json_response(200)

    conn
    |> recycle()
    |> as(token_b())
    |> put("/v1/data/search/#{@scope}/settings", %{"zeroHitStrategy" => "none"})
    |> json_response(200)

    assert SurfaceConfigs.get("documents", @scope, ws_a.id)["zero_hit_strategy"] == "typo_widen"
    assert SurfaceConfigs.get("documents", @scope, ws_b.id)["zero_hit_strategy"] == "none"
    # The global default row is untouched by either tenant's write.
    assert SurfaceConfigs.get("documents", @scope, nil)["zero_hit_strategy"] == "drop_tokens"
  end
end
