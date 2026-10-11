defmodule BarkparkWeb.FinderLocaleTest do
  @moduledoc """
  The public finder speaks the browser's language (lead ruling, run 8, the
  same rule as the sign-in pages): nb for an nb/no/nn Accept-Language, English
  without one, never the Default workspace's locale. The static render reads
  the header; the connected mount reads what `BarkparkWeb.AcceptLanguage`
  stored in the session, since a LiveView socket carries no request headers.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Tenancy

  defp with_language(conn, nil), do: conn
  defp with_language(conn, tag), do: put_req_header(conn, "accept-language", tag)

  test "an nb browser: the static page and the connected LiveView read Norwegian", %{conn: conn} do
    static = conn |> with_language("nb-NO,nb;q=0.9") |> get("/finder") |> html_response(200)
    assert static =~ ~s(<html lang="nb-NO")
    assert static =~ "Søk i alt."
    assert static =~ ~s(aria-label="Søk")

    {:ok, _view, html} = live(with_language(scoped_conn(), "nb"), "/finder")
    assert html =~ "Søk i alt."
    assert html =~ "skriv for å søke"
    refute html =~ "Search everything."
  end

  test "no Accept-Language: English", %{conn: conn} do
    static = conn |> get("/finder") |> html_response(200)
    assert static =~ ~s(<html lang="en")

    {:ok, _view, html} = live(scoped_conn(), "/finder")
    assert html =~ "Search everything."
    assert html =~ "type to search"
  end

  test "the Default workspace's locale never decides", %{conn: conn} do
    {:ok, _} = Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), "nb-NO")

    try do
      {:ok, _view, html} = live(conn, "/finder")
      assert html =~ "Search everything."
    after
      Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), "en")
    end
  end
end
