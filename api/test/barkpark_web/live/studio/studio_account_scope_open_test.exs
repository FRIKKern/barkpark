defmodule BarkparkWeb.Studio.StudioAccountScopeOpenTest do
  @moduledoc """
  Gyldendal, 2026-09-14: an ACCOUNT session (owner of Default, member of the
  twin) opened the scope switcher on the twin, picked Default Workspace →
  Default Project → production, and nothing happened — the menu closed.

  `scope-open` re-gates through `Shared.can_reach_workspace?/2`, whose
  non-token arm only matched the workspace the socket was ALREADY mounted in,
  so every account user was trapped in their current workspace. The user arm
  now asks membership of the user's own principal kind, like the token arm.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Tenancy}

  @dataset "production"

  setup %{conn: conn} do
    ws_a = create_workspace!("acct-switch-a-#{System.unique_integer([:positive])}")
    proj_a = create_project!(ws_a, "default")
    ws_b = create_workspace!("acct-switch-b-#{System.unique_integer([:positive])}")
    proj_b = create_project!(ws_b, "default")
    ws_c = create_workspace!("acct-switch-c-#{System.unique_integer([:positive])}")
    proj_c = create_project!(ws_c, "default")

    for proj <- [proj_a, proj_b, proj_c] do
      _ = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    end

    email = "acct-switch-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, user.id, "member", "user")
    {:ok, _} = Tenancy.Auth.create_membership(ws_b.id, user.id, "owner", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})

    {:ok,
     conn: conn,
     ws_a: ws_a,
     proj_a: proj_a,
     ws_b: ws_b,
     proj_b: proj_b,
     ws_c: ws_c,
     proj_c: proj_c}
  end

  defp studio(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  test "an account member of B opens B from A: scope-open navigates to B's studio root", %{
    conn: conn,
    ws_a: ws_a,
    proj_a: proj_a,
    ws_b: ws_b,
    proj_b: proj_b
  } do
    {:ok, view, _html} = live(conn, studio(ws_a, proj_a))

    render_click(view, "scope-menu-toggle", %{})
    render_click(view, "scope-menu-ws", %{"id" => ws_b.id})

    render_click(view, "scope-open", %{"ws" => ws_b.slug, "proj" => proj_b.slug, "ds" => @dataset})

    assert_redirect(view, studio(ws_b, proj_b))
  end

  test "an account that is NOT a member of C stays put: scope-open is a no-op", %{
    conn: conn,
    ws_a: ws_a,
    proj_a: proj_a,
    ws_c: ws_c,
    proj_c: proj_c
  } do
    {:ok, view, _html} = live(conn, studio(ws_a, proj_a))

    render_click(view, "scope-menu-toggle", %{})

    html =
      render_click(view, "scope-open", %{
        "ws" => ws_c.slug,
        "proj" => proj_c.slug,
        "ds" => @dataset
      })

    refute_redirected(view, studio(ws_c, proj_c))
    assert html =~ ws_a.name
  end
end
