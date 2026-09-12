defmodule Barkpark.PortableDoc.Render.StylesheetTest do
  @moduledoc """
  Pure unit test (no DB, no boot) for the ONE canonical paper-surface source.

  Guards the Stage-2 "single source, every sink" contract: `css/0` returns the
  extracted stylesheet, the source carries the sentinel tokens/rules, both
  layouts embed it, and no `[style*=]` de-inline hack leaked into the source.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Stylesheet
  alias Barkpark.PortableDoc.Render.Stylesheet.Comments

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

    test "is the on-disk source with every comment stripped, rules byte-intact" do
      source = File.read!(@surface_css)
      css = Stylesheet.css()

      # The served bytes ARE the source minus its comments — nothing else.
      assert css == Comments.strip(source)

      # Non-vacuity: the source really does carry comments, so the equality
      # above is a claim about stripping and not about two identical strings.
      assert String.contains?(source, "/*")
      assert byte_size(css) < byte_size(source)
    end

    test "carries no CSS comment delimiter at all" do
      refute String.contains?(Stylesheet.css(), "/*")
      refute String.contains?(Stylesheet.css(), "*/")
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

  # ── the "Unsupported block" grep trap (pbw-backlog-unsupported-grep-trap) ──
  #
  # `Stylesheet.css/0` is inlined into `<style>` in `<head>` on every /papers
  # page. One source comment explains the `.bp-unknown-block` degrade and quotes
  # the placeholder copy `render/walk.ex` emits for a forward-compat Pd-node
  # kind, so `curl … | grep -c "Unsupported block"` returned >= 1 on EVERY paper
  # — including papers with no unknown block — and no smoke gate written that
  # way could ever reach 0. Both arms below run against a FULL self-contained
  # document (`style: :article`, which embeds the stylesheet exactly as a page
  # does), so the CSS and the body are measured together, the way a curl does.
  #
  # Two arms, deliberately paired: the negative arm alone would stay green if
  # the walker stopped emitting unknown blocks entirely, and the positive arm
  # alone would stay green if the comment came back.
  describe "served paper bytes vs. the unknown-block signal" do
    @normal %{
      "kind" => "PdContainer",
      "children" => [
        %{"kind" => "PdHeading", "level" => 1, "children" => ["A normal paper"]},
        %{"kind" => "PdParagraph", "children" => ["Nothing unsupported here."]}
      ]
    }

    @with_unknown %{
      "kind" => "PdContainer",
      "children" => [
        %{"kind" => "PdParagraph", "children" => ["Before."]},
        %{"kind" => "PdHologram"},
        %{"kind" => "PdParagraph", "children" => ["After."]}
      ]
    }

    test "a normal paper's served page greps 0 for the prose" do
      page = Render.render_html(@normal, %{style: :article})

      # The control the negative arm needs: the stylesheet really is inlined in
      # this page, so a 0 count is a statement about the CSS, not about a page
      # that never carried it.
      assert String.contains?(page, "<style>")
      assert String.contains?(page, ".bp-paper-surface .bp-unknown-block")

      assert count(page, "Unsupported block") == 0
      assert count(page, "bp-unknown-block") == 1, "only the CSS rule, no markup"
    end

    test "an unknown block's served page carries the class a gate must count" do
      page = Render.render_html(@with_unknown, %{style: :article})

      assert String.contains?(page, ~s(<div class="bp-unknown-block">))
      assert count(page, ~s(class="bp-unknown-block")) == 1

      # The prose now appears ONCE and only inside that markup — never in CSS.
      assert count(page, "Unsupported block") == 1

      assert String.contains?(
               page,
               ~s(<div class="bp-unknown-block">Unsupported block: PdHologram)
             )
    end
  end

  defp count(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
