defmodule BarkparkWeb.Components.DraftDiffLocaleTest do
  @moduledoc """
  task-7b8e2a561579c2d9: the draft vs published diff read English in a
  Norwegian Studio — header, change count, column headers, row statuses and
  image cells. They now read in the Studio language.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.DraftDiff

  @schema %{
    "fields" => [
      %{"name" => "title", "title" => "Tittel", "type" => "string"},
      %{"name" => "cover", "title" => "Omslag", "type" => "image"}
    ]
  }

  defp diff(locale) do
    Gettext.with_locale(BarkparkWeb.Gettext, locale, fn ->
      render_component(&DraftDiff.draft_diff/1,
        schema: @schema,
        draft: %{
          content: %{
            "title" => "Ny",
            "cover" => %{"url" => "/a.png", "width" => 4, "height" => 3}
          }
        },
        published: %{content: %{"title" => "Gammel"}}
      )
    end)
  end

  test "the diff reads Norwegian under nb_NO" do
    html = diff("nb_NO")
    assert html =~ "Utkast mot publisert"
    assert html =~ "2 endringer"
    assert html =~ "Felt"
    assert html =~ "Endret"
    assert html =~ "Lagt til"
    assert html =~ "Bilde 4×3"
    assert html =~ "ingen alt-tekst"
    refute html =~ "Draft vs Published"
  end

  test "English reads as before" do
    html = diff("en")
    assert html =~ "Draft vs Published"
    assert html =~ "2 changes"
    assert html =~ "Changed"
    assert html =~ "Image 4×3"
  end
end
