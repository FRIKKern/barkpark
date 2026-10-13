defmodule BarkparkWeb.Studio.MediaStringsTest do
  @moduledoc """
  task-2bc7975ad3bdb737: the media library (bp-asset-explorer) had no strings
  hook, so it read English in every workspace. The server now stamps
  `StudioLocale.component_strings(:asset_explorer)` on both of its hosts, keyed
  by the English text; the component fills %{slots} itself.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias BarkparkWeb.StudioLocale

  @dataset "production"

  setup do
    on_exit(fn -> Gettext.put_locale(BarkparkWeb.Gettext, "en") end)
    :ok
  end

  test "the explorer's strings are Norwegian under nb_NO, with their slots intact" do
    Gettext.put_locale(BarkparkWeb.Gettext, "nb_NO")
    strings = Jason.decode!(StudioLocale.component_strings(:asset_explorer))

    assert strings["Collections"] == "Samlinger"
    assert strings["All assets"] == "Alle filer"
    assert strings["Upload"] == "Last opp"
    assert strings["image"] == "bilde"
    # The client fills the slot, so the server hands it through.
    assert strings["%{count} assets"] == "%{count} filer"

    assert strings["Showing %{loaded} of %{total} in %{name}"] ==
             "Viser %{loaded} av %{total} i %{name}"
  end

  test "under the default locale every value is its own English key" do
    Gettext.put_locale(BarkparkWeb.Gettext, "en")
    strings = Jason.decode!(StudioLocale.component_strings(:asset_explorer))

    assert map_size(strings) > 100
    assert Enum.all?(strings, fn {english, value} -> english == value end)
  end

  test "the Media page stamps the strings on the explorer", %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()
    raw = "media-strings-token-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(raw, "media-strings", @dataset, ["read", "write", "admin"], default_ws.id)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, view, html} = live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/media")

    assert has_element?(view, "bp-asset-explorer[data-strings]")
    [_, stamped] = Regex.run(~r/<bp-asset-explorer[^>]*\sdata-strings="([^"]*)"/, html)

    decoded =
      stamped
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
      |> String.replace("&amp;", "&")
      |> Jason.decode!()

    assert decoded["All assets"] == "All assets"
  end
end
