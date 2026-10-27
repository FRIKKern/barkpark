defmodule Barkpark.DeskIconsTest do
  @moduledoc """
  task-af038d8b0d769e82: one desk icon vocabulary for both Studios, Sanity's
  (@sanity/icons names). The LiveView Studio draws a Sanity name its own set
  lacks; a deskStructure naming anything else is answered with an advisory.
  """
  use BarkparkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias Barkpark.Content.Validation
  alias Barkpark.DeskIcons

  # Every name gyldendal.no's desk uses (its migrate/desk/sanity-structure.json).
  @twin ~w(block-element bolt book calendar case controls copy dashboard documents edit
           error-outline eye-closed eye-open filter help-circle home image info-outline
           library link menu olist package schema sparkles star tags unknown user users
           warning-outline)

  test "every name gyldendal.no's desk uses is a desk icon" do
    assert @twin -- DeskIcons.names() == []
    assert length(DeskIcons.names()) > 200
    refute DeskIcons.known?("no-such-icon")
    refute DeskIcons.known?(nil)
  end

  defp render_desk_icon(name, fallback \\ "file") do
    assigns = %{name: name, fallback: fallback}

    rendered_to_string(~H"""
    <BarkparkWeb.Icons.desk_icon name={@name} fallback={@fallback} />
    """)
  end

  test "the LiveView Studio draws every desk icon name, and a name it does not know as the fallback" do
    for name <- @twin do
      html = render_desk_icon(name)
      assert html =~ "<svg", "#{name} drew nothing"
    end

    # A Sanity-only name: Sanity's glyph, in its 25-unit box.
    assert render_desk_icon("eye-open") =~ ~s(data-desk-icon="eye-open")
    assert render_desk_icon("eye-open") =~ ~s(viewBox="0 0 25 25")
    # A name this Studio's own set has: its own glyph, as before.
    refute render_desk_icon("home") =~ "data-desk-icon"
    # Unknown: the fallback glyph, never a crash.
    assert render_desk_icon("no-such-icon", "folder") =~ "<svg"
  end

  test "a deskStructure naming an unknown icon gets an unknown_desk_icon warning per item, nested too" do
    content = %{
      "items" => [
        %{"title" => "Books", "icon" => "book"},
        %{
          "title" => "Odd",
          "icon" => "no-such-icon",
          "items" => [%{"title" => "Deeper", "icon" => "also-unknown"}]
        }
      ]
    }

    findings = Validation.desk_icon_findings("deskStructure", content)
    assert Enum.map(findings, & &1.path) == ["/items/1/icon", "/items/1/items/0/icon"]
    assert Enum.all?(findings, &(&1.code == :unknown_desk_icon))
    assert hd(findings).params == %{icon: "no-such-icon"}
    assert :unknown_desk_icon in Validation.known_codes()

    assert Validation.desk_icon_findings("post", content) == []

    assert Validation.desk_icon_findings("deskStructure", %{"items" => [%{"icon" => "tags"}]}) ==
             []
  end

  # task-e6c04c61beb4c717: six lucide icons a migrated Sanity schema uses as type
  # icons. Plain names where they are free; every one also as `lucide:<name>`,
  # the only spelling of lucide's tags (Sanity's own `tags` keeps its glyph).
  @lucide ~w(megaphone layout-grid graduation-cap languages user-pen)

  test "the six lucide icons a migrated schema uses are desk icons" do
    for name <- @lucide ++ Enum.map(@lucide ++ ["tags"], &("lucide:" <> &1)) do
      assert DeskIcons.known?(name), "#{name} is not a desk icon"
      assert render_desk_icon(name) =~ "<svg"
    end

    refute DeskIcons.body("lucide:tags") == DeskIcons.body("tags")

    assert Validation.desk_icon_findings("deskStructure", %{
             "items" => [%{"icon" => "lucide:tags"}, %{"icon" => "graduation-cap"}]
           }) == []
  end

  # task-374095d722922dde: every lucide icon gyldendal.no's twin names, as
  # `lucide:<name>`, in its schemas and its list preview icon picks. A schema type
  # or a row icon with one of these names draws it, not the document icon.
  @twin_lucide ~w(backpack book book-a book-copy book-dashed book-image book-open book-open-text
           book-plus book-text calendar-days cassette-tape circle-help clapperboard
           clipboard-list disc-3 download dumbbell earth file-audio files folder-open
           glasses globe graduation-cap headphones info languages layout-grid life-buoy list
           list-checks mail map megaphone message-circle-more mic-vocal monitor-play
           notebook-pen notebook-text package-open palette podcast presentation printer
           receipt-text scale scroll shapes spell-check table tablet-smartphone tags
           tv-minimal-play user-pen volume-2)

  test "every lucide icon the twin names draws as a type icon and a row icon" do
    names = Enum.map(@twin_lucide, &("lucide:" <> &1))
    assert length(names) == 56

    fallbacks = Enum.filter(names, &(BarkparkWeb.Icons.row_icon(&1) == "document"))

    assert fallbacks == [],
           "#{length(fallbacks)} fall back to document: #{Enum.join(fallbacks, " ")}"

    for name <- names do
      assert BarkparkWeb.Icons.type_icon(name) == name
      assert BarkparkWeb.Icons.type_icon_svg(name) =~ ~s(data-desk-icon="#{name}")

      assert DeskIcons.body(name) =~
               ~s|<g transform="translate(0.5 0.5)" stroke="currentColor" stroke-width="1.2"|
    end
  end
end
