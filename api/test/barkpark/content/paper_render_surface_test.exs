defmodule Barkpark.Content.PaperRenderSurfaceTest do
  @moduledoc """
  task-1d095b61a47bf057 — a NON-article paper's stored `body_html` is rendered
  on the SCREEN surface, not the mail one.

  `Labels.paper_render_opts/3` used to name `:style, :article` only when the
  paper carried `"article"`/`"article-wide"`; its fallback clause returned
  style-less opts, so `Render.render_block/2`'s `Map.get(opts, :style, :email)`
  default decided and every OTHER paper's `content["body_html"]` came out as
  inline-stamped EMAIL HTML. That string is exactly what the public web reader
  injects into `.bp-paper-surface` (`web/components/document-detail.tsx:22`), so
  mail-client typography was reaching a screen. Sibling of
  task-605ba8bfbd54c871 / PR #15973, which fixed the same defect on the
  DOCUMENT key `content["body"]["html"]`; this is the PAPERS cache key.

  The one consumer that genuinely wants inline email HTML,
  `bulldocs_email_controller.ex:39`, passes `style: :email` itself and
  re-renders from blocks — it never reads this cache, and
  `api/test/barkpark_web/controllers/bulldocs_email_controller_test.exs` is not
  edited by this row and stays green.

  ## The anti-vacuity guard

  `refute stored == email_html` is not decoration. Before the `:email` paragraph
  stamp (PR #15461/#15973) the `:article` and `:email` renders of a plain
  paragraph were the SAME bytes, which is why this defect hid. Drop that line
  and the test could pass vacuously over a still-broken render path.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Papers.DoctrineBackfill
  alias Barkpark.PortableDoc.Render

  defp para(id, text) do
    %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
  end

  # A paper with NO `style` — the population that fell to the `:email` default.
  defp seed_plain_paper(slug, blocks) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{"slug" => slug, "blocks" => blocks})
      )

    # The row must actually be non-article, or the assertions below are proving
    # the ALREADY-WORKING clause. This is the fixture's own non-vacuity check.
    refute get_in(doc.content, ["style"]) in ["article", "article-wide"]
    doc
  end

  describe "a non-article paper's body_html" do
    test "carries no inline email stamp, and equals the :article render" do
      slug = "render-surface-#{System.unique_integer([:positive])}"
      blocks = [para("p1", "body copy that must not carry mail type")]

      doc = seed_plain_paper(slug, blocks)
      stored = doc.content["body_html"]

      article_html = Render.render_blocks(blocks, %{style: :article})
      email_html = Render.render_blocks(blocks, %{style: :email})

      # 1. Not one byte of the `:email` paragraph stamp is persisted. Each of
      #    these declarations is emitted by the `:email` leg of the walker; if
      #    the fallback ever goes style-less again, they all reappear here.
      refute stored =~ "font-family:"
      refute stored =~ "font-size:"
      refute stored =~ "line-height:"
      refute stored =~ "style="

      # 2. It is the ARTICLE render, byte-exact. `:article`'s `<p>` is bare BY
      #    CONTRACT — `.bp-paper-surface p` is the single source of body
      #    typography in View and Edit.
      assert stored == article_html

      # 3. THE ANTI-VACUITY GUARD (see @moduledoc): the two surfaces really do
      #    differ for this very block, so assertion 2 is a CHOICE of surface and
      #    not two renders coincidentally agreeing.
      refute stored == email_html
      assert email_html =~ "font-size:17px"
    end

    # task-c46967eb3dc49e77 — the FIFTH style-less site, found by this row's
    # census and NOT in its filing. `upsert_paper` renders `body_html` through
    # `Labels.paper_render_opts/3` (`:article` since the row above) but
    # projected `content["body"]["html"]` through style-less
    # `Labels.render_opts/2` in `block_ops.maybe_project/6`, so ONE ROW stored
    # its body twice on TWO DIFFERENT SURFACES. This path persists via direct
    # Repo writes, so — unlike the document leg — it is NOT rescued downstream
    # by `Writer.maybe_project_document_content/2`.
    test "the projected content[body][html] matches body_html instead of splitting surfaces" do
      slug = "render-surface-split-#{System.unique_integer([:positive])}"
      blocks = [para("p1", "one row must not store two surfaces")]

      doc = seed_plain_paper(slug, blocks)

      body_html = doc.content["body_html"]
      projected = get_in(doc.content, ["body", "html"])
      article_html = Render.render_blocks(blocks, %{style: :article})
      email_html = Render.render_blocks(blocks, %{style: :email})

      assert is_binary(projected)

      refute projected =~ "font-family:"
      refute projected =~ "font-size:"
      refute projected =~ "line-height:"

      assert projected == article_html

      # The two keys agree — that is the whole point of this row.
      assert projected == body_html

      # ANTI-VACUITY: the surfaces really do differ for this block.
      refute article_html == email_html
      assert email_html =~ "font-size:17px"
    end

    test "the DoctrineBackfill re-projection keeps both the cache and the body off the mail surface" do
      # The two style-less mix backfills (composition_migration.ex,
      # doctrine_backfill.ex) rendered `body_html` through `paper_render_opts/3`
      # but re-projected `content["body"]` through plain style-less
      # `Labels.render_opts/2`, so a sweep put email HTML back into the
      # projected body even after the write path was fixed. Both now project on
      # the SAME opts. This exercises the doctrine one end-to-end; the
      # composition migration's `persist/2` is the byte-identical sibling.
      slug = "render-surface-backfill-#{System.unique_integer([:positive])}"
      seed_plain_paper(slug, [para("p1", "backfilled body copy")])

      {:ok, _stats} = DoctrineBackfill.run(dry_run: false)

      content = Content.get_paper(slug).content
      body_html = content["body_html"]
      projected = get_in(content, ["body", "html"])

      assert is_binary(projected)

      for html <- [body_html, projected] do
        refute html =~ "font-family:"
        refute html =~ "font-size:"
        refute html =~ "line-height:"
      end

      assert body_html == projected
      assert body_html =~ "backfilled body copy"
    end
  end
end
