defmodule Barkpark.Plugins.OnixEdit.Web.OnixEditLocaleTest do
  @moduledoc """
  OnixEdit's console pages speak the workspace's language (lead ruling, run 8:
  OnixEdit is used by Norwegian publisher staff, and Bokbasen is Norwegian).
  The staleness, Bokbasen and ping pages were written in English.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Tenancy}

  @token "onixedit-locale-admin-token"

  setup %{conn: conn} do
    ws = Tenancy.get_default_workspace()

    {:ok, _token} =
      Auth.create_token(
        @token,
        "onixedit locale",
        "production",
        ["read", "write", "admin"],
        ws.id
      )

    on_exit(fn -> Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), "en") end)
    %{conn: init_test_session(conn, %{"api_token" => @token})}
  end

  defp locale!(locale),
    do: {:ok, _} = Tenancy.set_workspace_locale(Tenancy.get_default_workspace(), locale)

  test "an nb workspace: staleness, Bokbasen and ping read Norwegian", %{conn: conn} do
    locale!("nb-NO")

    {:ok, _view, html} = live(conn, "/w/default/p/default/admin/onixedit/staleness")
    assert html =~ "OnixEdit – foreldede kodelister"
    assert html =~ "Gjeldende registerutgave:"
    refute html =~ "Codelist Staleness"

    {:ok, _view, html} = live(conn, "/w/default/p/default/admin/onixedit/bokbasen")
    assert html =~ "Innsendinger til Bokbasen"
    assert html =~ "Ingen innsendinger til Bokbasen ennå."
    refute html =~ "Bokbasen Submissions"

    {:ok, _view, html} = live(conn, "/studio/onixedit/ping")
    assert html =~ "OnixEdit · utvidelsesrute"
  end

  test "an English workspace reads as before", %{conn: conn} do
    locale!("en")

    {:ok, _view, html} = live(conn, "/w/default/p/default/admin/onixedit/staleness")
    assert html =~ "OnixEdit Codelist Staleness"

    {:ok, _view, html} = live(conn, "/w/default/p/default/admin/onixedit/bokbasen")
    assert html =~ "Bokbasen Submissions"
  end
end
