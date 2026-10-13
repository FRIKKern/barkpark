defmodule BarkparkWeb.Studio.StudioAccountSignOutTest do
  @moduledoc """
  An editor signed in with an account can sign out (task-095de037b3f3b47e).

  Found dogfooding: a user account that is a member of a non-default
  workspace signed in at /login and landed in its Studio with no Sign out
  control anywhere. The layout rendered it only for an `:api_token` session;
  an account session carries `:current_user` instead.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @sign_out ~s(form[action="/logout"] button[aria-label="Sign out"])

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "so-#{suffix}", name: "Sign-out Twin"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws: ws, proj: proj}
  end

  defp studio_url(ws, proj), do: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

  test "an account member of a non-default workspace sees Sign out",
       %{conn: conn, ws: ws, proj: proj} do
    email = "so-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})

    {:ok, view, _html} = live(conn, studio_url(ws, proj))

    assert has_element?(view, @sign_out)
  end

  test "a token session still sees Sign out", %{conn: conn, ws: ws, proj: proj} do
    raw = "so-token-" <> Ecto.UUID.generate()
    # Binding the token to the workspace also makes it a member there.
    {:ok, _token} = Auth.create_token(raw, "so-token", @dataset, ["read", "write"], ws.id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, view, _html} = live(conn, studio_url(ws, proj))

    assert has_element?(view, @sign_out)
  end

  test "an anonymous public-demo Studio has nothing to sign out of", %{conn: conn} do
    prev = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, true)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev) end)

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))

    refute has_element?(view, @sign_out)
  end
end
