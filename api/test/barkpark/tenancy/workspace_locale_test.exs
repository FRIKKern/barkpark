defmodule Barkpark.Tenancy.WorkspaceLocaleTest do
  @moduledoc """
  Gyldendal parity E7 — the workspace's Studio locale lives in the same
  `settings` bag as the theme, resolves to English for every workspace that
  never set one, refuses an unknown locale, and never clobbers the theme.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Tenancy
  alias BarkparkWeb.StudioLocale

  test "an untouched workspace speaks English, and nil is English too" do
    ws = create_workspace!("loc-default-#{System.unique_integer([:positive])}")
    assert Tenancy.workspace_locale(ws) == "en"
    assert Tenancy.workspace_locale(nil) == "en"
    assert StudioLocale.resolve(ws) == "en"
  end

  test "nb-NO persists, resolves to the gettext directory spelling, and keeps the theme" do
    ws = create_workspace!("loc-nb-#{System.unique_integer([:positive])}")
    {:ok, ws} = Tenancy.set_workspace_theme(ws, Tenancy.default_theme())
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")

    assert Tenancy.workspace_locale(ws) == "nb-NO"
    assert StudioLocale.resolve(ws) == "nb_NO"
    assert Tenancy.workspace_theme(ws) == Tenancy.default_theme()
    assert Tenancy.workspace_locale(Tenancy.get_workspace_by_id(ws.id)) == "nb-NO"
  end

  test "an unknown locale is refused before touching the row" do
    ws = create_workspace!("loc-bad-#{System.unique_integer([:positive])}")
    assert {:error, :unknown_locale} = Tenancy.set_workspace_locale(ws, "sv-SE")
    assert {:error, :unknown_locale} = Tenancy.set_workspace_locale(ws, nil)
    assert Tenancy.workspace_locale(Tenancy.get_workspace_by_id(ws.id)) == "en"
  end

  test "a stored value outside the known list degrades to English" do
    ws = create_workspace!("loc-stale-#{System.unique_integer([:positive])}")
    stale = %{ws | settings: Map.put(ws.settings || %{}, "locale", "xx-XX")}
    assert Tenancy.workspace_locale(stale) == "en"
  end

  test "put/1 switches the process locale for the render that follows" do
    ws = create_workspace!("loc-put-#{System.unique_integer([:positive])}")
    {:ok, ws} = Tenancy.set_workspace_locale(ws, "nb-NO")
    assert StudioLocale.put(ws) == "nb_NO"
    assert Gettext.get_locale(BarkparkWeb.Gettext) == "nb_NO"
    assert Gettext.gettext(BarkparkWeb.Gettext, "Publish") == "Publiser"
    assert StudioLocale.put(nil) == "en"
    assert Gettext.gettext(BarkparkWeb.Gettext, "Publish") == "Publish"
  end
end
