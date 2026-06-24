defmodule Barkpark.PortableDoc.Render.PalettesTest do
  # Pure module with no DB access — all helpers are constant/pure functions.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Palettes

  describe "constant accessors" do
    test "font_body returns the system-font stack" do
      assert Palettes.font_body() == "-apple-system,'SF Pro Text',system-ui,sans-serif"
    end

    test "font_mono returns the monospace stack" do
      assert Palettes.font_mono() == "ui-monospace,Menlo,monospace"
    end

    test "brand returns the indigo hex" do
      assert Palettes.brand() == "#4f46e5"
    end

    test "default_width returns 600" do
      assert Palettes.default_width() == 600
    end
  end

  describe "email_palette/0" do
    setup do
      {:ok, palette: Palettes.email_palette()}
    end

    test "style key is :email", %{palette: p} do
      assert p.style == :email
    end

    test "uses the system sans-serif font body", %{palette: p} do
      assert p.font_body == Palettes.font_body()
    end

    test "width is the default 600px", %{palette: p} do
      assert p.width == 600
    end

    test "paper background is pure white", %{palette: p} do
      assert p.paper == "#ffffff"
    end
  end

  describe "article_palette/0" do
    setup do
      {:ok, palette: Palettes.article_palette()}
    end

    test "style key is :article", %{palette: p} do
      assert p.style == :article
    end

    test "font_body is a serif stack", %{palette: p} do
      assert p.font_body =~ "serif"
    end

    test "width is wider than the email palette", %{palette: p} do
      assert p.width == 680
      assert p.width > Palettes.default_width()
    end

    test "bg embeds a CSS variable with hex fallback", %{palette: p} do
      assert p.bg =~ "var(--paper-bg"
      assert p.bg =~ "#"
    end
  end

  describe "palette_for/1" do
    test "returns article palette for :article" do
      assert Palettes.palette_for(:article).style == :article
    end

    test "returns email palette for :email" do
      assert Palettes.palette_for(:email).style == :email
    end

    test "returns email palette for unknown atoms (fallback)" do
      assert Palettes.palette_for(:unknown).style == :email
    end

    test "returns email palette for nil (fallback)" do
      assert Palettes.palette_for(nil).style == :email
    end
  end
end
