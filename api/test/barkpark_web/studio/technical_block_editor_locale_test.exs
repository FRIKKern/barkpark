defmodule BarkparkWeb.Studio.TechnicalBlockEditorLocaleTest do
  @moduledoc """
  task-1d00a3763bde719e: the Beta editor's technical block controls (diff, file
  tree, footnotes, code tabs) and the labels their in-place edit affordances
  announce were English in a Norwegian Studio. They now read in the Studio
  language.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.Studio.StudioLive.Components.TechnicalBlockEditor

  defp render(locale, block) do
    Gettext.with_locale(BarkparkWeb.Gettext, locale, fn ->
      render_component(&TechnicalBlockEditor.technical_block_editor/1,
        block: block,
        id: block["id"]
      )
    end)
  end

  @tabs %{
    "id" => "ct",
    "type" => "code-tabs",
    "syncKey" => "lang",
    "tabs" => [%{"label" => "Elixir", "language" => "elixir", "value" => "IO.puts(1)"}]
  }

  @notes %{"id" => "fn", "type" => "footnote", "notes" => [%{"id" => "a", "text" => "Først."}]}

  test "the controls and painted-copy labels read Norwegian under nb_NO" do
    tabs = render("nb_NO", @tabs)
    assert tabs =~ "Konfigurer kodefaner"
    assert tabs =~ "Synkroniseringsnøkkel"
    assert tabs =~ "Etikett"
    assert tabs =~ "Kode"
    assert tabs =~ "Legg til fane"
    assert tabs =~ "Flytt ned"
    refute tabs =~ "Configure code tabs"

    notes = render("nb_NO", @notes)
    assert notes =~ ~s(data-painted-copy-label="Fotnote")
    assert notes =~ "Legg til fotnote"
  end

  test "English reads as before" do
    tabs = render("en", @tabs)
    assert tabs =~ "Configure code tabs"
    assert tabs =~ "Add tab"
    assert render("en", @notes) =~ ~s(data-painted-copy-label="Footnote")
  end
end
