defmodule Barkpark.PortableDoc.Render.WalkTest do
  # Pure, in-process walker — no DB, no side-effects.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Walk
  alias Barkpark.PortableDoc.Render.Palettes

  @email Palettes.email_palette()
  @article Palettes.article_palette()
  @width 600

  # ── render_body/3 ──────────────────────────────────────────────────────────

  describe "render_body/3 — PdHr" do
    test "emits hr with default thickness 1 and palette rule colour" do
      html = Walk.render_body(%{"kind" => "PdHr"}, @width, @email)
      assert html == ~s(<hr style="border:none;border-top:1px solid #e5e7eb;margin:16px 0">)
    end

    test "respects explicit thickness" do
      html = Walk.render_body(%{"kind" => "PdHr", "thickness" => 3}, @width, @email)
      assert html =~ "border-top:3px solid"
    end
  end

  describe "render_body/3 — PdInlineCode" do
    test "escapes HTML entities inside value" do
      html = Walk.render_body(%{"kind" => "PdInlineCode", "value" => "a & <b>"}, @width, @email)
      assert html =~ "a &amp; &lt;b&gt;"
      assert html =~ "<code style="
    end

    test "uses empty string when value is absent" do
      html = Walk.render_body(%{"kind" => "PdInlineCode"}, @width, @email)
      assert html =~ "<code style="
      refute html =~ "nil"
    end
  end

  describe "render_body/3 — PdText" do
    test "emits bare span with no style when node has no decoration" do
      html = Walk.render_body(%{"kind" => "PdText", "children" => ["hello"]}, @width, @email)
      assert html == "<span>hello</span>"
    end

    test "combines bold + strike into correct style attributes" do
      node = %{
        "kind" => "PdText",
        "weight" => "bold",
        "strike" => true,
        "children" => ["x"]
      }

      html = Walk.render_body(node, @width, @email)
      assert html =~ "font-weight:bold"
      assert html =~ "text-decoration:line-through"
    end

    test "escapes HTML in string children" do
      node = %{"kind" => "PdText", "children" => ["<script>"]}
      html = Walk.render_body(node, @width, @email)
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end
  end

  describe "render_body/3 — PdLink" do
    test "wraps children in anchor with safe href" do
      node = %{"kind" => "PdLink", "href" => "https://example.com", "children" => ["go"]}
      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(href="https://example.com")
      assert html =~ "go"
      assert html =~ "<a "
    end

    test "javascript: href is sanitised by safe_url (returns # sentinel)" do
      node = %{"kind" => "PdLink", "href" => "javascript:alert(1)", "children" => ["bad"]}
      html = Walk.render_body(node, @width, @email)
      # safe_url returns "#" for unsafe schemes — never a bare javascript: in the DOM
      assert html =~ ~s(href="#")
      refute html =~ "javascript:"
    end
  end

  describe "render_body/3 — PdWikilink" do
    test "renders unresolved target as dotted span (no href)" do
      node = %{
        "kind" => "PdWikilink",
        "target" => "Missing Page",
        "children" => ["Missing Page"]
      }

      html = Walk.render_body(node, @width, @email)
      assert html =~ ~s(data-wikilink="Missing Page")
      assert html =~ "text-decoration:underline dotted"
      refute html =~ "<a "
    end

    test "renders resolved target as <a href=/papers/:id>" do
      pal = Map.put(@email, :wikilinks, %{"Home" => %{id: "doc-42"}})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Home",
        "children" => ["Home"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/doc-42")
      assert html =~ "<a "
    end
  end

  describe "render_body/3 — PdHeading (article only)" do
    test "emits <h2> for level 2 with article font" do
      node = %{"kind" => "PdHeading", "level" => 2, "children" => ["Title"]}
      html = Walk.render_body(node, @width, @article)
      assert html =~ "<h2 style="
      assert html =~ "font-size:24px"
      assert html =~ "Title</h2>"
    end

    test "clamps unknown level to h2" do
      node = %{"kind" => "PdHeading", "level" => 99, "children" => ["H?"]}
      html = Walk.render_body(node, @width, @article)
      assert html =~ "<h2 style="
    end
  end

  describe "render_body/3 — unhandled kind raises" do
    test "raises ArgumentError for unknown kind" do
      assert_raise ArgumentError, ~r/unhandled PdUnknownWidget/, fn ->
        Walk.render_body(%{"kind" => "PdUnknownWidget"}, @width, @email)
      end
    end
  end

  describe "render_body/3 — _raw passthrough" do
    test "emits pre-rendered HTML byte-exact" do
      raw = "<figure><pre class=\"mermaid\">graph LR; A-->B</pre></figure>"
      html = Walk.render_body(%{"kind" => "_raw", "html" => raw}, @width, @email)
      assert html == raw
    end
  end
end
