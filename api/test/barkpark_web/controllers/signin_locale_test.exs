defmodule BarkparkWeb.SigninLocaleTest do
  @moduledoc """
  The sign-in pages speak the browser's language (lead ruling, run 8).

  They have no workspace of their own and were written in English. Now:
  a `return_to` into `/w/<slug>/…` speaks that workspace's locale (E7);
  otherwise the browser's Accept-Language decides (nb, no, nn → nb-NO);
  otherwise English. Never the Default workspace's locale. `<html lang>`
  follows.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Tenancy}

  defp page(conn, path, accept \\ nil) do
    conn = if accept, do: put_req_header(conn, "accept-language", accept), else: conn
    conn |> get(path) |> html_response(200)
  end

  test "an nb browser gets a Norwegian sign-in page", %{conn: conn} do
    html = page(conn, "/login", "nb-NO,nb;q=0.9,en;q=0.8")
    assert html =~ ~s(<html lang="nb-NO")
    assert html =~ "Logg inn"
    assert html =~ "Glemt passordet?"
    assert html =~ ~s(aria-label="Vis passord")
    assert html =~ ~s(data-hide-label="Skjul passord")
    refute html =~ "Forgot password?"
  end

  test "no Accept-Language: English", %{conn: conn} do
    html = page(conn, "/login")
    assert html =~ ~s(<html lang="en")
    assert html =~ "Sign in"
    assert html =~ "Forgot password?"
  end

  test "the highest-q language the Studio speaks wins; Norwegian tags all read nb", %{conn: conn} do
    assert page(conn, "/login", "en-US,nb;q=0.8") =~ ~s(<html lang="en")
    assert page(scoped_conn(), "/login", "da,nb;q=0.5") =~ ~s(<html lang="nb-NO")
    assert page(scoped_conn(), "/login", "nn") =~ ~s(<html lang="nb-NO")
    assert page(scoped_conn(), "/login", "no-NO") =~ ~s(<html lang="nb-NO")
    assert page(scoped_conn(), "/login", "nb;q=0, de") =~ ~s(<html lang="en")
  end

  test "the Default workspace's locale never decides", %{conn: conn} do
    {:ok, _} = Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), "nb-NO")

    try do
      assert page(conn, "/login") =~ ~s(<html lang="en")
    after
      Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), "en")
    end
  end

  test "a return_to into a workspace speaks that workspace's language (E7)", %{conn: conn} do
    n = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "signin-nb-#{n}", name: "Signin #{n}"})
    {:ok, _} = Tenancy.set_workspace_locale(ws, "nb-NO")

    html = page(conn, "/login?return_to=/w/#{ws.slug}/p/default/d/production/studio", "en")
    assert html =~ ~s(<html lang="nb-NO")
    assert html =~ ~r{class="bp-auth-title">\s*Logg inn\s*</h1>}
  end

  test "the other sign-in pages follow the browser too", %{conn: conn} do
    assert page(conn, "/login/reset", "nb") =~ "Tilbakestill passordet"
    assert page(scoped_conn(), "/login/magic", "nb") =~ "Send meg en innloggingslenke"
  end

  test "a failed sign-in flashes in the browser's language", %{conn: conn} do
    {:ok, _user} =
      Accounts.register_user(%{
        email: "signin-nb-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    html =
      conn
      |> put_req_header("accept-language", "nb")
      |> post("/login/account", %{"email" => "nobody@example.com", "password" => "wrong-one-here"})
      |> html_response(200)

    assert html =~ "E-post eller passord er feil."
  end
end
