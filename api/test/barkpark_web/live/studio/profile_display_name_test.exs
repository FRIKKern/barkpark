defmodule BarkparkWeb.Studio.ProfileDisplayNameTest do
  @moduledoc """
  task-8d8dabe8b693031d: a signed-in editor sets their account's display name
  in the Studio profile dialog. The dialog's Name field writes it through the
  same `Accounts.update_display_name/2` door as `PATCH /v1/auth/display-name`,
  so the name follows the account to every browser, names the editor in
  presence, and names their media checkout locks
  (`Media.Storage.Actor.display/2`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Accounts
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  defp register! do
    email = "studio-dname-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    {:ok, _} =
      TenancyAuth.create_membership(
        Barkpark.TenancyFixtures.default_workspace_id!(),
        user.id,
        "member",
        "user"
      )

    user
  end

  defp session_conn(conn, user) do
    {:ok, raw} = Accounts.create_user_session_token(user)
    Plug.Test.init_test_session(conn, %{"user_session" => raw})
  end

  defp open_studio(conn), do: live(conn, scoped_studio("/d/#{@dataset}/studio"))

  test "saving the profile name sets the account's display name, and a new session shows it", %{
    conn: conn
  } do
    user = register!()
    {:ok, view, _} = open_studio(session_conn(conn, user))

    profile = render_click(view, "show-profile", %{})
    assert profile =~ "Saved to your account"

    render_submit(view, "save-profile", %{"name" => "  Ingrid Ness  ", "color" => "#3b82f6"})

    assert Accounts.get_user(user.id).display_name == "Ingrid Ness"
    refute render(view) =~ "profile-modal-dialog"

    # A fresh session (another browser, no stored name) reads the account's name.
    {:ok, _view2, html2} = open_studio(session_conn(build_conn_scoped(), user))
    assert html2 =~ "Ingrid Ness — open your profile"
    refute html2 =~ ~r/User [0-9a-z]{4} — open your profile/
  end

  test "an account with no display name keeps one fallback name on every render and in every browser",
       %{conn: conn} do
    # task-6db38e1365702602: the static render has no connect params, so a
    # name keyed on the per-browser id was random on every load.
    user = register!()
    expected = "User #{String.slice(user.id, 0..3)} — open your profile"
    path = scoped_studio("/d/#{@dataset}/studio")

    for _ <- 1..3 do
      static = conn |> session_conn(user) |> get(path) |> html_response(200)
      assert static =~ expected
    end

    for browser <- ["aaaa1111", "bbbb2222"] do
      {:ok, _view, html} =
        build_conn_scoped()
        |> session_conn(user)
        |> put_connect_params(%{"user_id" => browser})
        |> live(path)

      assert html =~ expected
      refute html =~ "User #{String.slice(browser, 0..3)}"
    end
  end

  test "a name over 80 characters is refused in the dialog and nothing is saved", %{conn: conn} do
    user = register!()
    {:ok, view, _} = open_studio(session_conn(conn, user))
    render_click(view, "show-profile", %{})

    html =
      render_submit(view, "save-profile", %{
        "name" => String.duplicate("x", 81),
        "color" => "#3b82f6"
      })

    assert html =~ ~s(data-test-id="profile-name-error")
    assert html =~ "Use at most 80 characters."
    assert html =~ ~s(aria-invalid="true")
    assert html =~ "profile-modal-dialog"
    assert Accounts.get_user(user.id).display_name == nil
  end

  test "a blank name clears the account's display name", %{conn: conn} do
    user = register!()
    {:ok, user} = Accounts.update_display_name(user, %{display_name: "Ola"})
    {:ok, view, html} = open_studio(session_conn(conn, user))
    assert html =~ "Ola — open your profile"

    render_click(view, "show-profile", %{})
    render_submit(view, "save-profile", %{"name" => "   ", "color" => "#3b82f6"})

    assert Accounts.get_user(user.id).display_name == nil
    # The session falls back to its generated name, not to an empty one.
    assert render(view) =~ ~r/User [0-9a-f]{4} — open your profile/
  end

  # task-acae5df91728ca9d: the field was prefilled with the generated
  # "User <hex>", so saving the dialog for a color change stored that
  # placeholder as the account's display name. It is now the placeholder,
  # and the form submitted as rendered leaves the display name unset.
  test "an account with no display name sees its generated name as a placeholder, and saving keeps it unset",
       %{conn: conn} do
    user = register!()
    {:ok, view, _} = open_studio(session_conn(conn, user))
    render_click(view, "show-profile", %{})

    input = view |> element("#profile-name-input") |> render()
    assert input =~ ~s(value="")
    assert [placeholder] = Regex.run(~r/placeholder="([^"]*)"/, input, capture: :all_but_first)
    assert placeholder =~ ~r/^User [0-9a-f]{4}$/

    view
    |> form("#profile-modal-dialog form")
    |> render_submit(%{"color" => "#ef4444"})

    assert Accounts.get_user(user.id).display_name == nil
    assert render(view) =~ "#{placeholder} — open your profile"
  end

  test "a session without an account still saves its name in the browser only", %{conn: conn} do
    {:ok, view, _} = open_studio(conn)
    render_click(view, "show-profile", %{})
    refute render(view) =~ "Saved to your account"

    render_submit(view, "save-profile", %{"name" => "Gjest", "color" => "#3b82f6"})

    assert_push_event(view, "save-identity", %{name: "Gjest"})
    refute render(view) =~ "profile-modal-dialog"
  end

  defp build_conn_scoped, do: scoped_conn()
end
