defmodule BarkparkWeb.QuizLocaleTest do
  @moduledoc """
  Lead ruling (run 8): the quiz host and play pages speak the quiz's workspace
  language, never the viewer's. They had no gettext at all, so a Norwegian
  audience read "The host removed you from this room" and "Answers are closed".

  Every quiz a room can bind resolves through `Content.get_public_document/3`,
  pinned to the seeded Default workspace, so the Default workspace's locale is
  the page's locale. A signed-in viewer whose own workspace is Norwegian does
  not change it: the play page is a public door.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.{Accounts, Quiz, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup do
    pin = "L" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> Quiz.stop_room(pin) end)
    %{pin: pin}
  end

  defp default_locale!(locale) do
    {:ok, _} = Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), locale)
  end

  test "an nb-NO quiz workspace: the host page and its <html lang> read Norwegian", %{
    conn: conn,
    pin: pin
  } do
    default_locale!("nb-NO")

    dead = conn |> get("/quiz/host/#{pin}") |> html_response(200)
    assert dead =~ ~s(<html lang="nb-NO")
    assert dead =~ "Åpner rommet …"

    {:ok, _view, html} = live(build_conn(), "/quiz/host/#{pin}")

    for word <- ["Hyperquiz · Vert", "Bli med på", "0 spillere", "Vis svaret", "Avslutt spillet"] do
      assert html =~ word, "expected #{inspect(word)} on the nb host page"
    end

    for english <- ["Hyperquiz · Host", "Join at", "Reveal answer", "End game"] do
      refute html =~ english
    end
  end

  test "an nb-NO quiz workspace: the play page reads Norwegian", %{conn: conn, pin: pin} do
    default_locale!("nb-NO")
    {:ok, _pid} = Quiz.ensure_room(pin)

    {:ok, view, html} = live(conn, "/quiz/play/#{pin}")
    assert html =~ "Hyperquiz · Spiller"
    assert html =~ "Rom <code>"

    assert view |> element("button.c0") |> render_click() =~ "Svaret er registrert"

    {:ok, _view, gone} = live(build_conn(), "/quiz/play/nobody-#{pin}")
    assert gone =~ "Ingen leder dette rommet akkurat nå"
  end

  # Same nb + axe pass: neither page had a main landmark (axe landmark-one-main).
  test "the host and play pages each have one main landmark", %{conn: conn, pin: pin} do
    {:ok, host, _} = live(conn, "/quiz/host/#{pin}")
    assert has_element?(host, "main.q-shell")
    {:ok, player, _} = live(build_conn(), "/quiz/play/#{pin}")
    assert has_element?(player, "main.q-shell")
  end

  test "an English quiz workspace reads as before", %{conn: conn, pin: pin} do
    default_locale!("en")
    {:ok, _view, html} = live(conn, "/quiz/host/#{pin}")
    assert html =~ "Hyperquiz · Host"
    assert html =~ "Reveal answer"
  end

  test "a signed-in viewer's own Norwegian workspace does not change the page", %{
    conn: conn,
    pin: pin
  } do
    default_locale!("en")

    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "quiz-viewer-#{n}", name: "Viewer #{n}"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    {:ok, user} =
      Accounts.register_user(%{
        email: "quiz-viewer-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "admin", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    signed_in = Plug.Test.init_test_session(conn, %{"user_session" => raw})

    {:ok, _pid} = Quiz.ensure_room(pin)
    {:ok, _view, html} = live(signed_in, "/quiz/play/#{pin}")
    assert html =~ "Hyperquiz · Player"
    refute html =~ "Hyperquiz · Spiller"
  end
end
