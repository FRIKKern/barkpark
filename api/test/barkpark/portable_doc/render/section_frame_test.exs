defmodule Barkpark.PortableDoc.Render.SectionFrameTest do
  @moduledoc """
  The framed-finale section variant (charter D19) — reader legs of the
  three-surface device. A `section` carrying `variant="framed"` gains
  `class="bp-section--framed"` on BOTH wrappers:

    * STACK leg — `compose_section_stack` stamps a FIXED-literal top-level
      `"class"` on its PdBox; the walker's `box_class_attr` emits it ONLY on
      `:article` palettes AND only from the fixed whitelist.
    * GRID leg — `section_grid_html` inlines the same `:article`-gated class
      on its outer flex-column div.

  Locked invariants:

    * UNFRAMED BYTE-IDENTITY — a variant-less section renders the exact
      pre-hook bytes; an UNKNOWN variant fail-softs to those same bytes.
    * EMAIL SUPPRESSION (both legs) — the `:email` render is byte-identical
      framed vs unframed (Outlook is inline-only; the class never emits).
    * WHITELIST INJECTION PIN — walk renders raw external Pd JSON, so an
      author-supplied `"class"` key outside the whitelist must NOT emit
      (open pass-through = arbitrary paper-surface class injection).
    * NEIGHBOURING SECTION-HEAD BEAT — the class lands on the section's OWN
      box div; a neighbouring section's wrapper stays CLASSLESS, so the
      `div:not([class]) > h2` section-head rule (paper-surface.css) still has
      its target. (Chromium-probed in the D19 spike: classing the stream
      wrapper kills the beat — borderTop 0px / marginTop 51.3px vs the
      healthy 2px / 91.96px.)

  KNOWN ONE-LINER (documented, accepted): a framed section whose FIRST child
  is an h2 loses the accidental flat-leg beat — its box div now carries a
  class, so `div:not([class]) > h2` no longer matches inside it. That beat was
  a pre-existing cross-leg divergence; the frame collapses it by design.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  @article %{style: :article}

  # The pre-hook stack render for a titled one-paragraph section (article mode)
  # — the same literal tripwire section_layout_test.exs pins.
  @stack_html ~s(<div style="display:flex;flex-direction:column">) <>
                ~s(<hr class="bp-hr" style="border-top-width:1px">) <>
                ~s(<span style="font-weight:bold">Finale</span>) <>
                ~s(<p>closing</p>) <>
                ~s(<hr class="bp-hr" style="border-top-width:1px"></div>)

  defp section do
    %{
      "type" => "section",
      "title" => "Finale",
      "blocks" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "closing"}]}
      ]
    }
  end

  defp framed, do: Map.put(section(), "variant", "framed")

  defp grid(b) do
    Map.put(b, "layout", %{"mode" => "grid", "tracks" => 2})
  end

  describe "stack leg — class on the section's own box div" do
    test "variant=framed emits class=\"bp-section--framed\" on the box wrapper (:article)" do
      html = Render.render_block(framed(), @article)

      assert String.starts_with?(
               html,
               ~s(<div class="bp-section--framed" style="display:flex;flex-direction:column">)
             )

      # Same interior bytes as the unframed stack — only the class attr differs.
      assert String.replace(html, ~s( class="bp-section--framed"), "", global: false) ==
               @stack_html
    end

    test "unframed byte-identity: a variant-less section renders the pre-hook bytes" do
      assert Render.render_block(section(), @article) == @stack_html
    end

    test "unknown variant fail-softs to the exact unframed bytes" do
      for variant <- ["boxed", "", "FRAMED", 42, true] do
        b = Map.put(section(), "variant", variant)

        assert Render.render_block(b, @article) == @stack_html,
               "variant #{inspect(variant)} must NOT class the wrapper"
      end
    end
  end

  describe "grid leg — class inline on the grid wrapper" do
    test "a framed grid section carries the class on its outer flex-column div (:article)" do
      html = Render.render_block(grid(framed()), @article)

      assert String.starts_with?(
               html,
               ~s(<div class="bp-section--framed" style="display:flex;flex-direction:column">)
             )

      assert html =~ "bp-section__grid"
    end

    test "an unframed grid section's outer div stays classless" do
      html = Render.render_block(grid(section()), @article)
      assert String.starts_with?(html, ~s(<div style="display:flex;flex-direction:column">))
      refute html =~ "bp-section--framed"
    end
  end

  describe "email suppression — both legs byte-identical" do
    test "stack leg: the :email render is byte-identical framed vs unframed" do
      assert Render.render_block(framed(), %{}) == Render.render_block(section(), %{})
    end

    test "grid leg: the :email degrade is byte-identical framed vs unframed" do
      assert Render.render_block(grid(framed()), %{}) ==
               Render.render_block(grid(section()), %{})
    end

    test "no bp-section--framed bytes reach any :email output" do
      refute Render.render_block(framed(), %{}) =~ "bp-section--framed"
      refute Render.render_block(grid(framed()), %{}) =~ "bp-section--framed"
    end
  end

  describe "whitelist injection pin — walk renders raw external Pd JSON" do
    defp raw_box(class) do
      %{
        "kind" => "PdBox",
        "class" => class,
        "style" => %{"flexDirection" => "column"},
        "children" => []
      }
    end

    test "an arbitrary author-supplied class key does NOT emit" do
      for class <- ["evil\" onmouseover=\"alert(1)", "bp-role-eyebrow", "bp-callout", "x"] do
        html = Render.render_html(raw_box(class), %{style: :article, doctype: false})

        assert html == ~s(<div style="display:flex;flex-direction:column"></div>),
               "class #{inspect(class)} must not pass the whitelist"
      end
    end

    test "the whitelisted class emits on :article only — never on :email" do
      article =
        Render.render_html(raw_box("bp-section--framed"), %{style: :article, doctype: false})

      assert article ==
               ~s(<div class="bp-section--framed" style="display:flex;flex-direction:column"></div>)

      email = Render.render_html(raw_box("bp-section--framed"), %{doctype: false})
      refute email =~ "bp-section--framed"
    end

    test "a non-binary class value stays inert" do
      for class <- [%{"x" => 1}, ["bp-section--framed"], 7] do
        html = Render.render_html(raw_box(class), %{style: :article, doctype: false})
        refute html =~ "class=", "class #{inspect(class)} must not emit"
      end
    end
  end

  describe "neighbouring section-head beat survives" do
    test "the section AFTER a framed finale keeps its classless wrapper (div:not([class]) > h2 target)" do
      neighbour = %{
        "type" => "section",
        "blocks" => [
          %{"type" => "heading", "level" => 2, "text" => "Next section"},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "body"}]}
        ]
      }

      html = Render.render_blocks([framed(), neighbour], @article)

      # Exactly ONE classed wrapper — the framed section's own box div.
      assert length(String.split(html, ~s(class="bp-section--framed"))) == 2

      # The neighbour's wrapper is the CLASSLESS flex-column div with the h2 as
      # its FIRST child — the exact DOM shape the paper-surface.css section-head
      # rule (`div:not([class]) > h2:first-child` → border-top beat) selects on.
      # No leading hairline: a section that opens with a heading lets the heading
      # carry the boundary alone (compose_section_stack/2).
      assert html =~
               ~s(<div style="display:flex;flex-direction:column"><h2>Next section</h2>)
    end
  end
end
