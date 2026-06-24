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
      assert html =~ "border-left:3px solid"
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
      assert html =~ "<div style="
      assert html =~ "§"
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

  describe "asciicast_html/3" do
    test "article mode emits bp-asciicast mount with safe_url" do
      html = Figures.asciicast_html("https://example.com/cast.json", "", :article)
      assert html =~ ~s(class="bp-asciicast")
      assert html =~ ~s(data-cast-src="https://example.com/cast.json")
    end

    test "email mode renders a plain link and no mount point" do
      html = Figures.asciicast_html("https://example.com/cast.json", "My cast", :email)
      assert html =~ "Terminal recording"
      refute html =~ "bp-asciicast"
    end

    test "unsafe URL is stripped by safe_url in article mode" do
      html = Figures.asciicast_html("javascript:alert(1)", "", :article)
      refute html =~ "javascript:"
    end
  end
end
