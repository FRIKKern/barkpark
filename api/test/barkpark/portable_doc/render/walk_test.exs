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

    test "id-pin: a carried doc_id resolves to /papers/:id with an EMPTY :wikilinks palette" do
      # Proves the id-pin bypasses title resolution — the palette has no entry
      # for "Setup" (in fact it has no entries at all), yet the pin still links.
      pal = Map.put(@email, :wikilinks, %{})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Setup",
        "doc_id" => "p-pinned-99",
        "children" => ["Setup"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/p-pinned-99")
      assert html =~ ~s(data-wikilink="Setup")
      assert html =~ "text-decoration:none"
      refute html =~ "dotted"
    end

    test "id-pin: doc_id wins over a clashing title entry (duplicate-title hole)" do
      # Two papers share the title "Setup"; the palette resolves the title to
      # the WRONG one. The pinned doc_id must override and link the picked paper.
      pal = Map.put(@email, :wikilinks, %{"Setup" => %{id: "wrong-doc"}})

      node = %{
        "kind" => "PdWikilink",
        "target" => "Setup",
        "doc_id" => "right-doc",
        "children" => ["Setup"]
      }

      html = Walk.render_body(node, @width, pal)
      assert html =~ ~s(href="/papers/right-doc")
      refute html =~ "wrong-doc"
    end

    test "no doc_id: empty/missing pin is byte-identical to the pre-pin render" do
      # A typed-not-picked wikilink (no doc_id) must round-trip exactly as
      # before — resolved via palette, dotted span when absent, and an empty
      # "" doc_id must NOT trigger the fast path.
      node = %{"kind" => "PdWikilink", "target" => "Home", "children" => ["Home"]}
      node_empty = Map.put(node, "doc_id", "")
      pal = Map.put(@email, :wikilinks, %{"Home" => %{id: "doc-42"}})

      # Resolved-via-palette path is untouched whether doc_id is absent or "".
      assert Walk.render_body(node, @width, pal) == Walk.render_body(node_empty, @width, pal)
      assert Walk.render_body(node, @width, pal) =~ ~s(href="/papers/doc-42")

      # Unresolved (empty palette) still degrades to the dotted span.
      bare = Map.put(@email, :wikilinks, %{})
      assert Walk.render_body(node, @width, bare) =~ "text-decoration:underline dotted"
      assert Walk.render_body(node_empty, @width, bare) == Walk.render_body(node, @width, bare)
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
