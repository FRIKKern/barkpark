defmodule BarkparkWeb.Studio.SettingsLocaleTest do
  @moduledoc """
  task-bc4ff44023a41186: Workspace Settings, the page where a workspace's Studio
  language is chosen, rendered English in an nb-NO workspace. Its title,
  sections, plugin list and credentials text now go through gettext.
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

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "settings-loc-#{suffix}", name: "Settings Locale"})

    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default Project"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "production"})
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    raw = "settings-loc-token-" <> Ecto.UUID.generate()

    {:ok, token} =
      Auth.create_token(raw, "settings-loc", @dataset, ["read", "write", "admin"], default_ws.id)

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

  test "an nb-NO workspace's Settings page is Norwegian", %{conn: conn, ws: ws, proj: proj} do
    html = render_live(conn, "/w/#{ws.slug}/p/#{proj.slug}/studio/settings")

    assert html =~ "Innstillinger for arbeidsområdet"
    assert html =~ "Tema for arbeidsområdet"
    assert html =~ "Studio-språk"
    assert html =~ "Påloggingsdata for utvidelser"
    assert html =~ "Tema, utvidelser og påloggingsdata for"
    assert html =~ ~s(aria-label="Kjør chat-rundene i dette arbeidsområdet i skysandkassen")

    refute html =~ "Workspace Settings"
    refute html =~ "Workspace theme"
    refute html =~ "Plugin credentials"
    refute html =~ "Theme, plugins and credentials for"
  end

  test "the default workspace's Settings page stays English", %{conn: conn} do
    {default_ws, default_proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    html = render_live(conn, "/w/#{default_ws.slug}/p/#{default_proj.slug}/studio/settings")

    assert html =~ "Workspace Settings"
    assert html =~ "Workspace theme"
    assert html =~ "Plugin credentials"
    refute html =~ "Innstillinger for arbeidsområdet"
  end
end
