defmodule Barkpark.PortableDoc.Render.ThemeResolveTest do
  # The theme thread is LIVE, not vacuously defaulted (charter D28, slice
  # ts-w4d). Two orthogonal proofs:
  #
  #   * NEGATIVE / byte-lock — the `:evergreen` default (and an unknown/nil
  #     theme, which Resolve folds onto evergreen) renders byte-IDENTICAL to a
  #     theme-less call. This is the same guarantee the email golden rides.
  #   * POSITIVE / liveness — a non-evergreen theme (colour-override map injected
  #     through the theme arg — the ts-w4b fixture-theme seam) moves the bytes
  #     end-to-end through every relocated colour: the walk palette (link accent,
  #     primary-button foreground), the email data-viz emitters, and the
  #     field-color swatch border.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.{DataViz, Palettes, TokensGen}

  # A theme injected as a {slot => value} override map — every slot deliberately
  # off the evergreen values so any live thread shows up in the bytes.
  @theme %{
    brand: "#ff0000",
    brand_text: "#00ff00",
    rule: "#0000ff",
    page_bg: "#abcdef",
    paper: "#fedcba",
    text: "#123456",
    muted: "#654321",
    code_bg: "#111111"
  }

  @button %{
    "kind" => "PdButton",
    "href" => "https://x.test",
    "label" => "Go",
    "priority" => "primary"
  }
  @stat %{"type" => "stat", "value" => "42", "max" => 100, "label" => "done"}
  @field_color %{"type" => "field-color", "label" => "brand", "value" => "#abcdef"}

  describe "evergreen default is byte-identical (Resolve semantics)" do
    test "no theme == :evergreen == unknown id, on a themed Pd-tree" do
      bare = Render.render_html(@button, %{doctype: false})
      ever = Render.render_html(@button, %{doctype: false, theme: :evergreen})
      unknown = Render.render_html(@button, %{doctype: false, theme: "no-such-theme"})
      nil_theme = Render.render_html(@button, %{doctype: false, theme: nil})

      assert bare == ever
      assert bare == unknown
      assert bare == nil_theme
      # and it carries the evergreen brand, not the override
      assert bare =~ "background:#1e5347"
      assert bare =~ "color:#ffffff"
    end

    test "email stat is byte-identical under evergreen / unknown / theme-less" do
      bare = DataViz.stat_email_html(@stat)
      ever = DataViz.stat_email_html(@stat, :evergreen)
      unknown = DataViz.stat_email_html(@stat, "no-such-theme")

      assert bare == ever
      assert bare == unknown
    end
  end

  describe "positive proof — a non-evergreen theme moves the bytes" do
    test "walk palette: link accent + primary-button foreground flip" do
      ever = Render.render_html(@button, %{doctype: false})
      themed = Render.render_html(@button, %{doctype: false, theme: @theme})

      refute themed == ever
      # button background = pal.accent (brand), foreground = pal.brand_text
      assert themed =~ "background:#ff0000"
      assert themed =~ "color:#00ff00"
    end

    test "email data-viz: the stat bar + label take the theme skin" do
      ever = DataViz.stat_email_html(@stat)
      themed = DataViz.stat_email_html(@stat, @theme)

      refute themed == ever
      # bar fill = accent, cell ground = page_bg, border = rule, label = muted
      assert themed =~ "#ff0000"
      assert themed =~ "#abcdef"
      assert themed =~ "#0000ff"
      assert themed =~ "#654321"
    end

    test "email heatmap: the accent-over-ground mix is theme-derived" do
      cells = %{"type" => "heatmap", "cells" => [[0.0, 1.0]]}
      ever = DataViz.heatmap_email_html(cells)
      themed = DataViz.heatmap_email_html(cells, @theme)

      refute themed == ever
      # ground-end of the mix (intensity 0.0) is exactly the theme page_bg
      assert themed =~ "#abcdef"
    end

    test "field-color swatch border resolves through the theme" do
      ever = Render.render_block(@field_color, %{style: :email})
      themed = Render.render_block(@field_color, %{style: :email, theme: @theme})

      refute themed == ever
      # evergreen rule vs override rule
      assert ever =~ "#dde7e2"
      assert themed =~ "#0000ff"
    end
  end

  describe "TokensGen theme-keying + Resolve (generated file)" do
    test "the committed theme set, default first" do
      assert TokensGen.themes() == [:evergreen, :charple, :ember, :fjord, :iris]
    end

    test "colour accessors default to evergreen and fold unknown → evergreen" do
      assert TokensGen.email_brand() == "#1e5347"
      assert TokensGen.email_brand(:evergreen) == "#1e5347"
      assert TokensGen.email_brand("no-such-theme") == "#1e5347"
      assert TokensGen.email_rule() == "#dde7e2"
      assert TokensGen.tone_ok() == "#137236"
      assert TokensGen.reading_accent() == "#a23925"
      assert TokensGen.callout(:success) == %{bg: "#e7f2ec", fg: "#1e6b52"}
      assert TokensGen.email_skin(:evergreen).brand == "#1e5347"
    end
  end

  describe "Palettes theme resolution" do
    test "palette_for threads the override into the palette colours" do
      ever = Palettes.palette_for(:email)
      themed = Palettes.palette_for(:email, @theme)

      assert ever.accent == "#1e5347"
      assert ever.brand_text == "#ffffff"
      assert themed.accent == "#ff0000"
      assert themed.link_color == "#ff0000"
      assert themed.brand_text == "#00ff00"
      assert themed.rule == "#0000ff"
    end

    test "an override map only merges known skin slots" do
      skin = Palettes.email_skin(%{brand: "#ff0000", bogus: "#000000"})
      assert skin.brand == "#ff0000"
      refute Map.has_key?(skin, :bogus)
    end

    test "brand/rule accessors take the theme arg, default evergreen" do
      assert Palettes.brand() == "#1e5347"
      assert Palettes.brand(@theme) == "#ff0000"
      assert Palettes.rule() == "#dde7e2"
      assert Palettes.rule(@theme) == "#0000ff"
    end
  end
end
