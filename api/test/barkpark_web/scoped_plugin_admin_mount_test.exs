defmodule BarkparkWeb.ScopedPluginAdminMountTest do
  @moduledoc """
  Wave 26, slice W26-2 — the scoped-mount rejection proof for the
  `:scoped_plugin_admin` live_session, exercised through Tickets `InboxLive`.

  `InboxLive` is the highest-severity plugin surface on this session: its
  `mint_key` handler mints a LIVE ticket-key credential, and — unlike the
  connectors exec-profile toggle W24 hardened — it has ZERO per-write re-gate.
  Every operator write trusts the mount. Its scoped route
  `/w/:ws/p/:proj/studio/tickets` rides `:scoped_plugin_admin`, whose mount
  gate was the same FLAT `{LiveAuth, :admin}` global-permission gate W24 proved
  escalatable: a token holding the flat global `admin` permission but only a
  MEMBER of the target workspace mounted the operator inbox and could mint keys.

  W26-1 (connectors-liveauth-admin-target-workspace) flips this session to
  `{LiveAuth, :scoped_admin}`, which authorizes the acting principal against the
  TARGET workspace's admin membership.

  ADDITIVE coverage (no production change of its own). It proves, against the
  W26-1 gate:

    * a TOKEN outsider (flat global `admin` + member-only of ws B) is REJECTED
      at mount of `/w/:ws/p/:proj/studio/tickets` (redirect, not `{:ok, view}`);
    * a legit ws-B admin MOUNTS the operator inbox (no over-tight lockout).

  RED-FIRST: on origin/main the rejection assertion FAILS — the outsider mounts
  the inbox (the live vuln). It goes GREEN only on the W26-1 mount gate.
  `scoped_plugin_session_test.exs` (the sibling that pins the member/cookie
  path) stays green under the same gate and is the no-regression companion in
  this slice's gate command.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup %{conn: conn} do
    ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "tickets-wsb-#{System.unique_integer([:positive])}",
        name: "Tickets WS B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # TOKEN outsider: flat global admin perm (clears the pre-fix :admin gate and
    # the :scoped_browser membership gate, since it IS a member), member-only of B.
    outsider_raw = "tickets-outsider-#{System.unique_integer([:positive])}"

    {:ok, outsider} =
      Auth.create_token(outsider_raw, "tickets outsider", "production", [
        "read",
        "write",
        "admin"
      ])

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, outsider.id)

    # Legit ws-B admin: global admin perm AND an admin membership row in B.
    admin_raw = "tickets-wsb-admin-#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Auth.create_token(admin_raw, "tickets wsb admin", "production", ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, admin.id, "admin")

    {:ok,
     conn: conn,
     scoped_path: "/w/#{ws_b.slug}/p/default/studio/tickets",
     outsider_raw: outsider_raw,
     admin_raw: admin_raw}
  end

  describe "scoped /w/:ws/p/:proj/studio/tickets (InboxLive) — rejected at mount" do
    test "a TOKEN outsider (global admin perm, member-only of B) is redirected, never mounted", %{
      conn: conn,
      scoped_path: path,
      outsider_raw: raw
    } do
      conn = init_test_session(conn, %{"api_token" => raw})

      # RED on origin/main: the :scoped_browser membership gate passes (member)
      # and the flat :admin mount gate passes (global perm), so the outsider
      # mounts the inbox and can mint a live ticket key. GREEN on W26-1: the
      # :scoped_admin gate sees workspace_admin?/2 = member → halt.
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, path)
    end

    test "a legit ws-B admin MOUNTS the operator inbox", %{
      conn: conn,
      scoped_path: path,
      admin_raw: raw
    } do
      conn = init_test_session(conn, %{"api_token" => raw})

      assert {:ok, _view, html} = live(conn, path)
      # The operator inbox surface (empty on the dead render, but present).
      assert html =~ ~s(data-test-id="inbox-list")
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
      nil ->
        {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

      _proj ->
        :ok
    end

    ws
  end
end
