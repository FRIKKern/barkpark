defmodule Barkpark.PortableDoc.Render.FiguresTest do
  # Pure leaf string-emitters — no DB, safe to run async.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Figures

  describe "encode_mermaid/1" do
    test "encodes & < > in that order" do
      assert Figures.encode_mermaid("A & B <c> d") == "A &amp; B &lt;c&gt; d"
    end

    test "leaves plain text without special chars untouched" do
      assert Figures.encode_mermaid("graph TD\n  A -- B") == "graph TD\n  A -- B"
    end

    test "double-encodes correctly: & becomes &amp; not &&amp;" do
      assert Figures.encode_mermaid("&amp;") == "&amp;amp;"
    end
  end

  describe "figcaption_inner/1" do
    test "empty string returns empty string" do
      assert Figures.figcaption_inner("") == ""
    end

    test "Figure N. pattern bolds the lead and appends escaped rest" do
      result = Figures.figcaption_inner("Figure 1. Some caption text")
      assert result == "<b>Figure 1.</b> Some caption text"
    end

    test "caption without Figure N. convention is HTML-escaped as-is" do
      result = Figures.figcaption_inner("Just a plain caption <with> html")
      assert result == "Just a plain caption &lt;with&gt; html"
    end

    test "Figure N. with no trailing text produces only the bold lead" do
      result = Figures.figcaption_inner("Figure 2.")
      assert result == "<b>Figure 2.</b>"
    end
  end

  describe "code_block_html/1" do
    test "wraps value in <pre> with expected inline styles" do
      html = Figures.code_block_html("hello world")
      assert html =~ "<pre style="
      assert html =~ "hello world"
      # task-ddb1e0ab09a62466: the slab is the mark. The S8 terracotta left bar
      # (`border-left:var(--bp-codeblock-accent-w, 3px) solid
      # var(--paper-reading-accent, …)`) is gone — it only ever existed because
      # the reader body painted --paper-bg-deep and the slab could not be seen.
      assert html =~ "background:var(--paper-bg-deep, #eaf1ee);border:0;"
      refute html =~ "border-left"
      refute html =~ "--paper-reading-accent"
    end

    test "HTML-escapes the value inside the code block" do
      html = Figures.code_block_html("<script>alert(1)</script>")
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end
  end

  describe "section_divider_html/0" do
    test "emits a div containing the § glyph" do
      html = Figures.section_divider_html()
      assert html =~ ~s(<div class="bp-section-divider" style=)
      assert html =~ "§"
    end

    # The class is a HANDLE, not styling: the reader shell needs to be able to say
    # "this divider sits directly in front of a section head, which already draws
    # that boundary" (paper-surface.css §divider dedup), and a class-less box
    # gives a stylesheet nothing to say it about. So the values must all still be
    # INLINE — view_edit_parity_test.exs §8 compares those declarations against
    # the edit mirror, and a value that migrated into a class rule would leave
    # that comparison passing over an empty set.
    test "carries the class as a positional handle only — every value stays inline" do
      html = Figures.section_divider_html()

      assert html =~ ~s(class="bp-section-divider" style="position:relative;)
      assert html =~ ~s(class="bp-section-divider__mark" style="position:relative;)
      assert html =~ "border-top:1px solid var(--paper-rule"
      assert html =~ "margin:2.4rem 0"
    end

    # The § mask hides the hairline behind the glyph, so it must be the PAGE
    # colour — `--paper-bg`, the token the reader body (bulldocs.html.heex, emitted
    # by design/emit.mjs) and the Studio `.bp-paper-surface` both stand on. While
    # the reader body was painted `--paper-bg-deep` the deep mask was invisible;
    # with the body on `--paper-bg` (task-ddb1e0ab09a62466) a deep mask would
    # render as a tile around the §.
    test "the § mask paints the page token, not the fill token" do
      html = Figures.section_divider_html()

      assert html =~ "padding:0 0.8rem;background:var(--paper-bg, #f6faf9)"
      refute html =~ "background:var(--paper-bg-deep"
    end
  end

  describe "diagram_html/3" do
    test "article mode wraps source in <pre class=\"mermaid\"> inside <figure>" do
      html = Figures.diagram_html("graph TD\nA-->B", "", :article)
      assert html =~ ~s(<pre class="mermaid">graph TD\nA--&gt;B</pre>)
      assert html =~ "<figure style="
      assert html =~ "</figure>"
    end

    test "article mode with caption includes figcaption" do
      html = Figures.diagram_html("A-->B", "Figure 3. A diagram", :article)
      assert html =~ "<figcaption"
      assert html =~ "<b>Figure 3.</b>"
    end

    test "email mode escapes source and omits the mermaid class" do
      html = Figures.diagram_html("graph TD\nA-->B", "", :email)
      refute html =~ ~s(class="mermaid")
      assert html =~ "&gt;"
    end
  end

  describe "asciicast_html/4" do
    test "article mode emits bp-asciicast mount with safe_url" do
      html = Figures.asciicast_html("https://example.com/cast.json", "", "", :article)
      assert html =~ ~s(class="bp-asciicast")
      assert html =~ ~s(data-cast-src="https://example.com/cast.json")
    end

    test "email mode renders a plain link and no mount point" do
      html = Figures.asciicast_html("https://example.com/cast.json", "My cast", "", :email)
      assert html =~ "Terminal recording"
      refute html =~ "bp-asciicast"
    end

    test "unsafe URL is stripped by safe_url in article mode" do
      html = Figures.asciicast_html("javascript:alert(1)", "", "", :article)
      refute html =~ "javascript:"
    end

    test "a set poster rides data-cast-poster on the article mount" do
      html = Figures.asciicast_html("https://example.com/cast.json", "", "npt:0:12", :article)
      assert html =~ ~s(data-cast-poster="npt:0:12")
      # ORDER matters: the attribute sits between src and style, so the JS twin
      # (blocks/core.ts) and the pd-golden bytes agree.
      assert html =~
               ~s(data-cast-src="https://example.com/cast.json" data-cast-poster="npt:0:12" style=)
    end

    test "a valid row limit makes a compact player available to the client" do
      html = Figures.asciicast_html("https://example.com/cast.json", "", "", 18, :article)
      assert html =~ ~s(data-cast-rows="18")
    end

    test "an unsafe row limit is omitted" do
      html = Figures.asciicast_html("https://example.com/cast.json", "", "", 2, :article)
      refute html =~ "data-cast-rows"
    end

    test "an unset poster leaves the mount byte-identical (no attribute)" do
      html = Figures.asciicast_html("https://example.com/cast.json", "", "", :article)
      refute html =~ "data-cast-poster"
    end

    test "poster is attribute-escaped" do
      html = Figures.asciicast_html("https://example.com/cast.json", "", ~s(a" onx="1), :article)
      refute html =~ ~s(onx="1")
      assert html =~ "&quot;"
    end

    test "email mode ignores poster entirely (no player runtime)" do
      html = Figures.asciicast_html("https://example.com/cast.json", "", "npt:0:12", :email)
      refute html =~ "data-cast-poster"
      assert html =~ "Terminal recording"
    end
  end
end
