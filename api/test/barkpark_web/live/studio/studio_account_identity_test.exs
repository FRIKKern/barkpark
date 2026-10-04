defmodule BarkparkWeb.Studio.StudioAccountIdentityTest do
  @moduledoc """
  A signed-in editor sees their account on their own avatar, and that email
  never leaves their own socket.

  Found dogfooding: signed in as an editor, the avatar read "U" and its label
  "User islf — open your profile" — the localStorage presence handle. The fix
  is SELF-ONLY: presence meta goes to every socket in the presence room
  (share-link and edit-share grant holders included), so the email must not
  ride it. Other viewers keep seeing the handle.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.PresenceState

  @dataset "production"

  defp signed_in_conn(conn) do
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
    {email, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end

  test "a signed-in member's own avatar names their account", %{conn: conn} do
    {email, conn} = signed_in_conn(conn)
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))

    assert html =~ "#{email} — open your profile"
    refute html =~ ~r/User [0-9a-z]{4} — open your profile/
  end

  test "the email never enters presence, so another viewer on the topic never receives it", %{
    conn: conn
  } do
    {email, member_conn} = signed_in_conn(conn)
    {:ok, member_view, _} = live(member_conn, scoped_studio("/d/#{@dataset}/studio"))
    _ = render(member_view)

    # The payload every socket in this workspace + project + dataset room
    # receives (owner ruling #30 Q7 keyed the room by project and dataset).
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    topic = PresenceState.topic(ws.id, proj.id, @dataset)

    metas =
      topic
      |> BarkparkWeb.Presence.list()
      |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas end)

    assert metas != [], "the member's socket should be tracked on #{topic}"
    refute inspect(metas) =~ email

    # A second, different viewer on the same workspace (here an anonymous
    # demo-studio socket, the same channel a share or grant holder joins)
    # renders the member only by handle.
    {:ok, other_view, _} = live(build_conn(), scoped_studio("/d/#{@dataset}/studio"))
    refute render(other_view) =~ email
  end
end
