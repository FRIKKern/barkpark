defmodule BarkparkWeb.Studio.ChromeLocaleTest do
  @moduledoc """
  task-7cf960756f738c6e: only the desk (StudioLive) put the workspace's Studio
  locale, so Media, Settings and every other chrome surface of an nb-NO
  workspace rendered English, `<html lang="en">` included. The locale now rides
  `BarkparkWeb.StudioChrome.on_mount/4`, which every studio-layout
  live_session runs.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    suffix = System.unique_integer([:positive])

    {:ok, ws} = Tenancy.create_workspace(%{slug: "chrome-loc-#{suffix}", name: "Chrome Locale"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "chrome-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "chrome-loc", @dataset, ["read", "write", "admin"], default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "owner")

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    {:ok, conn: conn, ws: ws, proj: proj}
  end

  defp render_live(conn, path) do
    case live(conn, path) do
      {:ok, _view, html} -> html
      {:error, {:live_redirect, %{to: to}}} -> elem(live(conn, to), 2)
      {:error, {:redirect, %{to: to}}} -> elem(live(conn, to), 2)
    end
  end

  test "the Media page of an nb-NO workspace is Norwegian", %{conn: conn, ws: ws, proj: proj} do
    path = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/media"

    assert conn |> get(path) |> html_response(200) =~ ~s(<html lang="nb-NO")

    html = render_live(conn, path)
    assert html =~ ~s(aria-label="Logg ut")
    refute html =~ ~s(aria-label="Sign out")
  end

  test "the Settings page of an nb-NO workspace is Norwegian", %{conn: conn, ws: ws, proj: proj} do
    path = "/w/#{ws.slug}/p/#{proj.slug}/studio/settings"

    assert conn |> get(path) |> html_response(200) =~ ~s(<html lang="nb-NO")

    html = render_live(conn, path)
    assert html =~ ~s(aria-label="Logg ut")
    refute html =~ ~s(aria-label="Sign out")
  end

  test "the default workspace's Media page stays English", %{conn: conn} do
    {default_ws, default_proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    path = "/w/#{default_ws.slug}/p/#{default_proj.slug}/d/#{@dataset}/studio/media"

    assert conn |> get(path) |> html_response(200) =~ ~s(<html lang="en")
    assert render_live(conn, path) =~ ~s(aria-label="Sign out")
  end
end
