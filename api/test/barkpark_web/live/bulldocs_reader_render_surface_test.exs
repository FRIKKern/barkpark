defmodule BarkparkWeb.BulldocsReaderRenderSurfaceTest do
  @moduledoc """
  task-c46967eb3dc49e77, site (1) — the PUBLIC LiveView paper reader's
  NON-article branch renders on the SCREEN surface, not the mail one.

  `BulldocsLive.render_opts/1` had two clauses: `true -> %{style: :article}`
  and `false -> %{}`. The style-less one let
  `Render.render_block/2`'s `Map.get(opts, :style, :email)` default decide, so
  a paper with no `content["style"]` — the whole non-article population — was
  streamed to a browser in inline MAIL typography.

  This is a SECOND, independent style-less source on the very surface #16037
  (task-1d095b61a47bf057) fixed for the stored `body_html`: after that PR the
  cache was stamp-free while the LIVE reader still stamped, so the two
  disagreed byte-for-byte for exactly the non-article rows.

  `bulldocs_email_controller.ex:39` — the one caller that genuinely wants
  `:email` — names it itself, re-renders from blocks, and is untouched by this
  row; `api/lib/barkpark/portable_doc/render.ex` is not in this diff either.

  ## The anti-vacuity guards

  1. The fixture asserts the seeded paper is really NON-article
     (`refute get_in(doc.content, ["style"]) in ["article", "article-wide"]`),
     so the test cannot silently drift onto the already-working `true` clause.
  2. `refute article_html == email_html` — before the `:email` paragraph stamp
     (#15461/#15973) the two surfaces rendered a plain paragraph to the SAME
     bytes, which is why this defect hid. Without that line the byte equality
     below could pass over a still-broken render path.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Render

  defp para(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}

  test "a NON-article paper streams the :article bytes and carries no email stamp", %{conn: conn} do
    slug = "reader-render-surface-#{System.unique_integer([:positive])}"
    block = para("p1", "reader body copy that must not carry mail type")

    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{"slug" => slug, "blocks" => [block]})
      )

    # GUARD 1: the row must actually be non-article, or this proves the
    # already-working clause.
    refute get_in(doc.content, ["style"]) in ["article", "article-wide"]

    {:ok, _view, html} = live(conn, "/papers/#{slug}")

    article_html = Render.render_block(block, %{style: :article})
    email_html = Render.render_block(block, %{style: :email})

    # GUARD 2: the two surfaces really do differ for this very block.
    refute article_html == email_html
    assert email_html =~ "font-size:17px"

    # Pull OUR paragraph out of the page rather than grepping the whole
    # document: `root.html.heex` inlines the `.bp-paper-surface` stylesheet,
    # which legitimately names the same font stack, so a whole-page
    # `refute html =~ "font-family:"` would red on the layout's own CSS.
    [fragment] =
      Regex.run(
        ~r{<p[^>]*>reader body copy that must not carry mail type</p>},
        html
      )

    # The reader emits the ARTICLE bytes, verbatim: `:article`'s `<p>` is bare
    # BY CONTRACT — `.bp-paper-surface p` is the single source of body
    # typography for the screen.
    assert fragment == article_html

    # ...and not one byte of the `:email` paragraph stamp. Named individually
    # so a revert reds on the exact declaration that reappeared.
    refute fragment =~ "style="
    refute fragment =~ "font-family:"
    refute fragment =~ "font-size:17px"
    refute fragment =~ "line-height:1.55"
    refute html =~ email_html
  end
end
