defmodule Barkpark.Content.PapersReaderHtmlTest do
  @moduledoc """
  `Content.Papers.reader_html/3` — the reader HTML every static paper door
  shares (`ShareLinkController`'s fallback, `ScopedPaperController`, and
  Studio's write-denied `:paper_html` feed) — pt-backlog-kill-the-body-html-cache.

  The property under test: a paper with blocks is rendered from its blocks on
  the read, so a stored `body_html` cache that says something the blocks do not
  never reaches the output. Each fixture plants a cache carrying a marker the
  blocks cannot produce; the marker's absence is only meaningful because the
  same test also proves the blocks' own prose IS in the output.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Labels}
  alias Barkpark.PortableDoc.Render

  @cache_marker "CACHE-ONLY-MARKER-never-in-blocks"

  defp blocks(text) do
    [
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    ]
  end

  defp paper(content) do
    %Document{doc_id: "reader-html", dataset: "test", type: "paper", title: "T", content: content}
  end

  describe "a paper with blocks" do
    test "renders from the blocks and never serves a lagging stored cache" do
      blocks = blocks("Prose from the blocks")

      # No `body_html_sv` stamp: the cache claims nothing about this renderer,
      # so reader_source classifies it as lagging (stale) and blocks win.
      doc = paper(%{"blocks" => blocks, "body_html" => "<p>#{@cache_marker}</p>"})

      assert {:ok, html} = Content.Papers.reader_html(doc, "test", [])

      assert html =~ "Prose from the blocks"
      refute html =~ @cache_marker
      assert html == Render.render_blocks(blocks, Labels.paper_render_opts("test", nil, []))
    end

    test "renders from the blocks when there is no stored cache at all" do
      blocks = blocks("Blocks only, no cache")
      doc = paper(%{"blocks" => blocks, "style" => "article"})

      assert {:ok, html} = Content.Papers.reader_html(doc, "test", [])
      assert html =~ "Blocks only, no cache"

      assert html ==
               Render.render_blocks(blocks, Labels.paper_render_opts("test", "article", []))
    end

    test "a cache stamped by the current renderer that disagrees with the blocks is refused, not served" do
      doc =
        paper(%{
          "blocks" => blocks("Prose from the blocks"),
          "body_html" => "<p>#{@cache_marker}</p>",
          "body_html_sv" => Render.body_html_render_version()
        })

      assert {:error, :ambiguous_source} = Content.Papers.reader_html(doc, "test", [])
    end
  end

  describe "a legacy paper with no blocks" do
    test "serves its sanitized body_html, because there is nothing to render from" do
      doc =
        paper(%{"body_html" => ~s|<h1>Legacy prose</h1><script>alert(1)</script><p>kept</p>|})

      assert {:ok, "<h1>Legacy prose</h1><p>kept</p>"} =
               Content.Papers.reader_html(doc, "test", [])
    end

    test "passes a semantic-empty refusal through instead of answering blank" do
      doc = paper(%{"body_html" => "<script>steal()</script>"})
      assert {:error, :semantic_empty} = Content.Papers.reader_html(doc, "test", [])
    end
  end

  test "a non-document is not found" do
    assert {:error, :not_found} = Content.Papers.reader_html(nil, "test", [])
  end
end
