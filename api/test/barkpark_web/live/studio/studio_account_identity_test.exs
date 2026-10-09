defmodule BarkparkWeb.Studio.StudioAccountIdentityTest do
  @moduledoc """
  A signed-in editor's avatar, profile dialog and presence name agree, and the
  account email stays inside the editor's own profile dialog
  (task-9f31f04ab4882f7d, revising task-28aea4a555586ce6).

  Found dogfooding: the avatar read the email's "E" while the profile dialog
  and every peer showed the generated presence name ("User 35ek"), so an
  editor could not tell the name was theirs. Ruling (a): the avatar shows the
  presence name; the email appears only in the profile dialog. Presence meta
  goes to every socket in the presence room (share-link and edit-share grant
  holders included), so the email never rides it.
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

  test "the avatar shows the presence name, never the email", %{conn: conn} do
    {email, conn} = signed_in_conn(conn)
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))

    [label] =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("button.presence-me-group")
      |> LazyHTML.attribute("aria-label")

    refute label =~ email
    refute label =~ "@"
    assert label =~ ~r/^User [0-9a-z]{4} — open your profile$/

    # The profile dialog names the same presence name, and it alone shows the
    # account (the viewer's own socket only).
    profile = render_click(view, "show-profile", %{})

    [account] =
      profile
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([data-test-id="profile-account"]))
      |> Enum.map(&LazyHTML.text/1)

    assert account =~ "Signed in as #{email}"
    name = String.replace_suffix(label, " — open your profile", "")
    # A generated name is the field's placeholder, not its value, so Save does
    # not store it as the display name (task-acae5df91728ca9d).
    assert profile =~ ~s(placeholder="#{name}")
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
