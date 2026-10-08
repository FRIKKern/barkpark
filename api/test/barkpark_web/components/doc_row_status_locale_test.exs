defmodule BarkparkWeb.StudioComponents.DocRowStatusLocaleTest do
  @moduledoc """
  task-98c8f1294f80ecf3: a desk list row's accessible name and the status
  badge carried the raw English status ("draft") in a Norwegian Studio. The
  word now goes through `Panes.status_word/1`; the CSS modifier stays raw.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias BarkparkWeb.StudioComponents.Panes

  setup do
    on_exit(fn -> Gettext.put_locale(BarkparkWeb.Gettext, "en") end)
  end

  defp row(attrs) do
    render_component(
      &Panes.pane_doc_item/1,
      Map.merge(
        %{
          phx_click: "select",
          phx_value_pane: "2",
          phx_value_id: "pub-1",
          title: "Fjellet",
          doc_id: "pub-1",
          status: "published"
        },
        attrs
      )
    )
  end

  test "in nb_NO a draft row is named utkast and a published row publisert" do
    Gettext.put_locale(BarkparkWeb.Gettext, "nb_NO")

    assert row(%{is_draft: true}) =~ ~s(aria-label="Fjellet, utkast")
    assert row(%{status: "published"}) =~ ~s(aria-label="Fjellet, publisert")
    refute row(%{is_draft: true}) =~ ~s(aria-label="Fjellet, draft")
  end

  test "the status badge reads the word, the class keeps the raw status" do
    Gettext.put_locale(BarkparkWeb.Gettext, "nb_NO")
    html = render_component(&Panes.status_badge/1, %{status: "draft"})

    assert html =~ "status-draft"
    assert html =~ "utkast"
  end

  test "English keeps the English words, and an unknown status reads as written" do
    assert row(%{is_draft: true}) =~ ~s(aria-label="Fjellet, draft")
    assert row(%{status: "archived"}) =~ ~s(aria-label="Fjellet, archived")
  end
end
