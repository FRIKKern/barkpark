defmodule Barkpark.PortableDoc.Render.StylesheetTest do
  @moduledoc """
  Pure unit test (no DB, no boot) for the ONE canonical paper-surface source.

  Guards the Stage-2 "single source, every sink" contract: `css/0` returns the
  extracted stylesheet, the source carries the sentinel tokens/rules, both
  layouts embed it, and no `[style*=]` de-inline hack leaked into the source.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Stylesheet

  @layout_root Path.expand("../../../../lib/barkpark_web/layouts", __DIR__)
  @root_heex Path.join(@layout_root, "root.html.heex")
  @bulldocs_heex Path.join(@layout_root, "bulldocs.html.heex")
  @layouts_ex Path.expand("../../../../lib/barkpark_web/layouts.ex", __DIR__)
  @surface_css Path.expand(
                 "../../../../assets/paper-surface/paper-surface.css",
                 __DIR__
               )

  describe "css/0" do
    test "returns a non-empty CSS string" do
      css = Stylesheet.css()
      assert is_binary(css)
      assert String.length(css) > 500
    end

    test "carries the sentinel tokens and element rules" do
      css = Stylesheet.css()
      # --bp-* typography token (Stage-1 single-source)
      assert String.contains?(css, "--bp-h1-size:")
      # --paper-* theme token
      assert String.contains?(css, "--paper-ink:")
      # portable element rule
      assert String.contains?(css, ".bp-paper-surface h1")
    end

    test "is byte-identical to the on-disk source file" do
      assert Stylesheet.css() == File.read!(@surface_css)
    end

    test "contains NO [style*= de-inline hack selectors (theme-vs-data line)" do
      refute String.contains?(Stylesheet.css(), "[style*=")
    end

    test "steps suppress the native ordered-list marker on each item" do
      css = Stylesheet.css()

      assert Regex.match?(
               ~r/\.bp-paper-surface\s+\.bp-steps__step\s*\{[^}]*list-style:\s*none;/s,
               css
             ),
             """
             .bp-paper-surface ol li assigns decimal markers directly to every
             ordered-list item. The steps component must therefore suppress the
             native marker on .bp-steps__step itself, not only on its parent ol,
             or Safari paints both "1." and the component's circled "1".
             """
    end
  end

  describe "sinks embed the source" do
    test "root.html.heex (Studio) embeds Stylesheet.css/0 via the paper_stylesheet/0 helper" do
      # The lone raw(Stylesheet.css()) was HOISTED out of root.html.heex into
      # Layouts.paper_stylesheet/0 (Sobelow's XSS.Raw fingerprint is line-numbered,
      # so an inline `# sobelow_skip` only attaches to a real .ex def, never inside
      # HEEx). The template now embeds the css THROUGH that helper — assert both the
      # template's call and the helper's embed, so the sink is still gate-covered.
      assert String.contains?(File.read!(@root_heex), "paper_stylesheet()")

      assert String.contains?(
               File.read!(@layouts_ex),
               "Barkpark.PortableDoc.Render.Stylesheet.css()"
             )
    end

    test "bulldocs.html.heex (/papers reader) embeds Stylesheet.css/0" do
      heex = File.read!(@bulldocs_heex)
      assert String.contains?(heex, "Barkpark.PortableDoc.Render.Stylesheet.css()")
    end

    test "root.html.heex no longer DEFINES the --bp-* tokens (moved to source)" do
      # A `var(--bp-h1-size)` reference is fine; a `--bp-h1-size:` definition is not.
      refute String.contains?(File.read!(@root_heex), "--bp-h1-size:")
    end
  end
end
