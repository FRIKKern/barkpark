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
end
