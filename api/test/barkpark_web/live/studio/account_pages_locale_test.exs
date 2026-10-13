defmodule BarkparkWeb.Studio.AccountPagesLocaleTest do
  @moduledoc """
  task-52e5ad56c2340350: since #22154 every Studio page puts the workspace's
  locale, but the account data page, the plugins page, org admin and the API
  tester had no gettext, so an nb-NO workspace still read them in English.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "acct-loc-#{suffix}", name: "Account Locale"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    {:ok, user} =
      Accounts.register_user(%{
        email: "acct-loc-#{suffix}@example.test",
        password: "correct-horse-battery"
      })

    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    {:ok, _} = TenancyAuth.create_membership(default_ws.id, user.id, "member", "user")
    {:ok, session} = Accounts.create_user_session_token(user)

    raw = "acct-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "acct-loc", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    {:ok, conn: conn, ws: ws, proj: proj, session: session, token: raw}
  end

  defp render_live(conn, path) do
    case live(conn, path) do
      {:ok, _view, html} -> html
      {:error, {:live_redirect, %{to: to}}} -> elem(live(conn, to), 2)
      {:error, {:redirect, %{to: to}}} -> elem(live(conn, to), 2)
    end
  end

  test "the account data page of an nb-NO workspace is Norwegian", ctx do
    conn = Plug.Test.init_test_session(ctx.conn, %{"user_session" => ctx.session})
    html = render_live(conn, "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}/d/#{@dataset}/studio/_account")

    assert html =~ "Dataene dine"
    assert html =~ "Last ned dataene mine"
    assert html =~ "Slett kontoen min"
    assert html =~ "Nåværende passord"
    refute html =~ "Download my data"
    refute html =~ "Erase my account"
  end

  # The plugins surface is the global registry; its admin session derives the
  # workspace from the principal (no LiveScope), so the admin here is homed in
  # the nb-NO workspace.
  test "the plugins page of an nb-NO workspace is Norwegian", ctx do
    raw = "acct-loc-home-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(raw, "acct-loc-home", @dataset, ["read", "write", "admin"], ctx.ws.id)

    conn = Plug.Test.init_test_session(ctx.conn, %{"api_token" => raw})
    html = render_live(conn, "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}/d/#{@dataset}/studio/_plugins")

    assert html =~ "Last inn alle utvidelser på nytt"
    assert html =~ "Oppdater"
    refute html =~ "Reload all plugins"
  end

  test "the default workspace's account data page stays English", ctx do
    {default_ws, default_proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    conn = Plug.Test.init_test_session(ctx.conn, %{"user_session" => ctx.session})

    html =
      render_live(
        conn,
        "/w/#{default_ws.slug}/p/#{default_proj.slug}/d/#{@dataset}/studio/_account"
      )

    assert html =~ "Download my data"
    assert html =~ "Erase my account"
  end
end
