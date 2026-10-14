defmodule BarkparkWeb.LiveAuthLocaleTest do
  @moduledoc """
  task-7efa49ea242a3e04 — found by run8-studio dogfooding as a member in an
  nb-NO agency workspace: visiting `/w/agency/p/default/studio/connectors`
  without admin authority redirected to `/studio` with the English flash
  "Admin access required", even though the rest of that Studio spoke
  Norwegian.

  `BarkparkWeb.LiveAuth`'s `:admin`/`:ops`/`:scoped_admin` hooks run FIRST in
  the on_mount chain, before `BarkparkWeb.StudioChrome.on_mount` ever sets
  the workspace's Gettext locale — so a denial flash from any of them was
  hardcoded English for every member, Norwegian workspace or not. This file
  pins the fix: the denial flash now reads in the TARGET workspace's own
  language.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup %{conn: conn} do
    ensure_default_scope!()
    suffix = System.unique_integer([:positive])

    {:ok, ws_nb} = Tenancy.create_workspace(%{slug: "agency-#{suffix}", name: "Agency"})
    {:ok, _} = Tenancy.create_project(ws_nb, %{slug: "default", name: "Default"})
    {:ok, ws_nb} = Tenancy.set_workspace_locale(ws_nb, "nb-NO")

    {:ok, ws_en} = Tenancy.create_workspace(%{slug: "overseas-#{suffix}", name: "Overseas"})
    {:ok, _} = Tenancy.create_project(ws_en, %{slug: "default", name: "Default"})

    {:ok, conn: conn, ws_nb: ws_nb, ws_en: ws_en}
  end

  defp member_conn!(conn, workspace, role \\ "member") do
    email = "liveauth-locale-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = TenancyAuth.create_membership(workspace.id, user.id, role, "user")

    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  describe ":scoped_admin denial (the exact repro — /studio/connectors)" do
    test "a plain member of an nb-NO workspace sees the denial flash in Norwegian", %{
      conn: conn,
      ws_nb: ws
    } do
      conn = member_conn!(conn, ws)

      assert {:error, {:redirect, %{to: "/studio", flash: flash}}} =
               live(conn, "/w/#{ws.slug}/p/default/studio/connectors")

      assert flash["error"] == "Administratortilgang kreves"
    end

    test "a plain member of an en workspace still sees the English flash (unchanged)", %{
      conn: conn,
      ws_en: ws
    } do
      conn = member_conn!(conn, ws)

      assert {:error, {:redirect, %{to: "/studio", flash: flash}}} =
               live(conn, "/w/#{ws.slug}/p/default/studio/connectors")

      assert flash["error"] == "Admin access required"
    end

    test "an unresolvable workspace slug falls back to English (no workspace to put a locale from)",
         %{conn: conn} do
      email = "liveauth-locale-nouser-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
      {:ok, raw} = Accounts.create_user_session_token(user)
      conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})

      assert {:error, {:redirect, %{to: "/studio", flash: flash}}} =
               live(conn, "/w/no-such-workspace-at-all/p/default/studio/connectors")

      assert flash["error"] == "Admin access required"
    end
  end

  # task-d8e3d76ad251bf73: a FLAT admin route has no workspace in the URL. The
  # flash used to take Default's locale (English); it now takes the caller's
  # own workspace — the one `ScopeResolver` lands them in, which is where the
  # denial redirect sends them.
  describe ":admin denial on a flat route (/studio/styleguide)" do
    test "a plain member of an nb-NO workspace sees the denial flash in Norwegian", %{
      conn: conn,
      ws_nb: ws
    } do
      conn = member_conn!(conn, ws)

      assert {:error, {:redirect, %{flash: flash}}} = live(conn, "/studio/styleguide")
      assert flash["error"] == "Administratortilgang kreves"
    end

    test "a plain member of an en workspace keeps the English flash", %{conn: conn, ws_en: ws} do
      conn = member_conn!(conn, ws)

      assert {:error, {:redirect, %{flash: flash}}} = live(conn, "/studio/styleguide")
      assert flash["error"] == "Admin access required"
    end

    test "a member of nb-NO AND of Default is still answered in Norwegian (Default is demoted)",
         %{conn: conn, ws_nb: ws} do
      {default_ws, _} = ensure_default_scope!()
      conn = member_conn!(conn, ws)
      %{"user_session" => raw} = Plug.Conn.get_session(conn)
      {user, _} = Accounts.verify_user_session(raw)
      {:ok, _} = TenancyAuth.create_membership(default_ws.id, user.id, "member", "user")

      assert {:error, {:redirect, %{flash: flash}}} = live(conn, "/studio/styleguide")
      assert flash["error"] == "Administratortilgang kreves"
    end
  end
end
