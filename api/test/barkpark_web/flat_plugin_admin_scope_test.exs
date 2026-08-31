defmodule BarkparkWeb.FlatPluginAdminScopeTest do
  @moduledoc """
  task-e656670726427b96 — the FLAT `/studio/tickets` mount must bind to the
  operator's OWN workspace, never the seeded Default.

  `Barkpark.Plugins.Tickets.InboxLive` is mounted twice. The scoped route
  `/w/:ws/p/:proj/studio/tickets` rides `:scoped_plugin_admin`, which carries
  `{PluginScopeSession, :scope}` — it bridges `:scoped_browser`'s resolved
  workspace across the HTTP→WebSocket boundary, so `StudioChrome`'s
  Default-pinning fallback no-ops on its truthy-assign guard. That surface is
  fine and is NOT what this file covers.

  The FLAT route `/studio/tickets` rides `:plugin_admin`, whose on_mount list is
  `[LiveAuth :admin, LiveAuth :require_org_mfa, StudioChrome :default]` — no
  workspace producer at all. `LiveAuth :admin` gates on the workspace-BLIND
  `admin` permission and assigns only `:api_token`, so
  `StudioChrome.default_scope_fallback/1` was the only producer and it pinned
  the seeded Default workspace for EVERY admin, including one whose token is
  bound to another workspace.

  All four ticket-key arms read that assign (`inbox_live.ex` `workspace/1` /
  `workspace_id/1`), so the defect is not merely a read disclosure — a
  workspace-B admin MINTS a live credential into Default and can rotate, pause
  and unpause Default's existing keys. `Keys.scope_workspace/2` is fail-closed
  and correct; it is handed the wrong workspace and faithfully confines the
  operator to the wrong tenant. The bug is UPSTREAM of that fence.

  RED-BEFORE: on `origin/main` every test in this file fails — the ws-B admin
  sees Default's key, the mint lands in Default, and the rotate of a Default
  key succeeds. They go green on the `derive_scope_from_principal/1` step that
  runs BEFORE the Default fallback (the LiveView analogue of the HTTP
  `DeriveWorkspaceFromToken` → `AssignDefaultScope` ordering).
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Plugins.Tickets.Keys
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @flat_path "/studio/tickets"
  @dataset "production"

  setup %{conn: conn} do
    default_ws = ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "flat-tickets-b-#{System.unique_integer([:positive])}",
        name: "Flat Tickets B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # A workspace-BOUND admin: holds the global `admin` permission (so the flat
    # `LiveAuth :admin` gate passes) and `api_tokens.workspace_id` points at B.
    raw = "flat-tickets-admin-#{System.unique_integer([:positive])}"

    {:ok, _token} =
      Auth.create_token(
        raw,
        "flat tickets ws-b admin",
        @dataset,
        ["read", "write", "admin"],
        ws_b.id
      )

    # One ticket key in each tenant, so an empty listing can never pass
    # vacuously — the ws-B row MUST render and the Default row MUST NOT.
    {:ok, %{key: default_key}} =
      Keys.mint(%{name: "DEFAULT-TENANT-KEY", workspace_id: default_ws.id, dataset: @dataset})

    {:ok, %{key: b_key}} =
      Keys.mint(%{name: "WSB-OWN-KEY", workspace_id: ws_b.id, dataset: @dataset})

    %{
      conn: init_test_session(conn, %{"api_token" => raw}),
      default_ws: default_ws,
      ws_b: ws_b,
      default_key: default_key,
      b_key: b_key
    }
  end

  describe "flat /studio/tickets binds to the operator's own workspace" do
    test "the key list shows B's keys and NEVER Default's", %{conn: conn} do
      {:ok, view, _html} = live(conn, @flat_path)

      html = render_click(view, "open_keys", %{})

      # Non-vacuous: the operator's OWN key must be present...
      assert html =~ "WSB-OWN-KEY",
             "the ws-B admin should see their own workspace's ticket key"

      # ...and the other tenant's must not.
      refute html =~ "DEFAULT-TENANT-KEY",
             "flat /studio/tickets leaked the Default workspace's ticket keys to a ws-B admin"
    end

    test "a mint lands in B, not Default", %{conn: conn, ws_b: ws_b, default_ws: default_ws} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "mint_key", %{"name" => "MINTED-BY-WSB-ADMIN"})

      minted = Repo.get_by(ApiToken, name: "MINTED-BY-WSB-ADMIN")

      # Bound as a boolean so assert/2 can actually surface the message — a
      # `assert %ApiToken{} = minted, "..."` match-assert silently discards it.
      refute is_nil(minted), "the mint should have created a ticket key"

      assert minted.workspace_id == ws_b.id,
             "a ws-B admin minted a live ticket credential into workspace " <>
               "#{inspect(minted.workspace_id)} instead of their own #{inspect(ws_b.id)}"

      refute minted.workspace_id == default_ws.id
      refute "MINTED-BY-WSB-ADMIN" in Enum.map(Keys.list(default_ws), & &1.name)
      assert "MINTED-BY-WSB-ADMIN" in Enum.map(Keys.list(ws_b), & &1.name)
    end

    test "a rotate cannot reach Default's key", %{conn: conn, default_key: default_key} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "rotate_key", %{"id" => default_key.id})

      after_rotate = Repo.get!(ApiToken, default_key.id)

      assert after_rotate.token_hash == default_key.token_hash,
             "a ws-B admin rotated the Default workspace's ticket key from the flat mount"
    end

    test "a pause cannot reach Default's key", %{conn: conn, default_key: default_key} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "pause_key", %{"id" => default_key.id})

      after_pause = Repo.get!(ApiToken, default_key.id)

      assert is_nil(after_pause.paused_at),
             "a ws-B admin paused the Default workspace's ticket key from the flat mount"
    end

    # PAIRED POSITIVE CONTROL for the two negatives above. Without it, a green
    # "Default's key is untouched" is three worlds in one: a correct scope
    # refusal, an unrelated error, or a dead handler that mutates nothing
    # anywhere. This proves the SAME socket drives a real rotate/pause through
    # to completion — so the Default no-op is the fence refusing, not the arm
    # being inert.
    test "the same socket DOES rotate and pause B's own key", %{conn: conn, b_key: b_key} do
      {:ok, view, _html} = live(conn, @flat_path)

      render_click(view, "open_keys", %{})
      render_click(view, "rotate_key", %{"id" => b_key.id})

      rotated = Repo.get!(ApiToken, b_key.id)

      refute rotated.token_hash == b_key.token_hash,
             "the rotate arm did not reach the operator's OWN key — the negatives above " <>
               "would then be green for the wrong reason"

      render_click(view, "pause_key", %{"id" => b_key.id})
      assert %ApiToken{paused_at: %DateTime{}} = Repo.get!(ApiToken, b_key.id)
    end
  end

  describe "the instance-wide operator (no workspace of its own) keeps Default" do
    # POPULATION 2. `LiveAuth :admin` gates on the workspace-BLIND global `admin`
    # permission, so the flat mount admits two identities: a workspace-BOUND
    # token (covered above — the defect) and a genuinely instance-wide token
    # whose `api_tokens.workspace_id` is nil.
    #
    # For the second there is no truer tenant to bind to, so the Default
    # fallback stands and this test PINS that deliberately. It is not the defect
    # under a new name: the defect was OVERRIDING a principal's own workspace
    # with Default. Here there is nothing being overridden — Default is the flat
    # posture's documented context (`LiveAuth.authorize_user/3` measures this
    # very population's admin authority on the Default workspace), and it is
    # exactly the nil-token carve-out the shipped HTTP sibling
    # `DeriveWorkspaceFromToken` already makes ("no regression on the nil-token
    # path"). Narrowing it here would diverge the two pipelines and lock the
    # host operator out of the surface, which the row explicitly forbids.
    setup %{conn: conn} do
      raw = "flat-tickets-instance-#{System.unique_integer([:positive])}"

      {:ok, _token} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "instance-wide operator",
          dataset: @dataset,
          permissions: ["read", "write", "admin"]
        })
        |> Repo.insert()

      %{conn: init_test_session(conn, %{"api_token" => raw})}
    end

    test "mounts, sees Default's keys, and mints into Default", %{
      conn: conn,
      default_ws: default_ws
    } do
      {:ok, view, _html} = live(conn, @flat_path)

      html = render_click(view, "open_keys", %{})
      assert html =~ "DEFAULT-TENANT-KEY"

      render_click(view, "mint_key", %{"name" => "MINTED-BY-INSTANCE-OP"})

      minted = Repo.get_by(ApiToken, name: "MINTED-BY-INSTANCE-OP")

      assert %ApiToken{} = minted
      assert minted.workspace_id == default_ws.id
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  defp ensure_default! do
    ws =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default"})
          ws

        ws ->
          ws
      end

    case Tenancy.get_default_project() do
      nil -> {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
      _proj -> :ok
    end

    ws
  end
end
