defmodule BarkparkWeb.Studio.StudioAccountIdentityTest do
  @moduledoc """
  A signed-in editor is named by their account in Studio, not by a random
  browser handle. Found dogfooding: signed in as an editor, the avatar read
  "U" and its label "User islf — open your profile" — the localStorage
  presence handle — so collaborators on one document could not tell each
  other apart.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  test "a signed-in member's avatar and presence name are their account", %{conn: conn} do
    email = "studio-name-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    {:ok, _} =
      TenancyAuth.create_membership(
        Barkpark.TenancyFixtures.default_workspace_id!(),
        user.id,
        "member",
        "user"
      )

    {:ok, raw} = Accounts.create_user_session_token(user)
    conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})

    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))

    assert html =~ "#{email} — open your profile"
    refute html =~ ~r/User [0-9a-z]{4} — open your profile/
  end
end
