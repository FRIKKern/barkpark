defmodule Barkpark.Content.ClassicFormRenderSurfaceTest do
  @moduledoc """
  task-c46967eb3dc49e77, site (2) — the CLASSIC form's re-projection
  (`Content.Forms.classic_save_content/4`, forms.ex) names the SCREEN surface.

  ## WHAT THE FILING GOT WRONG, proved here

  The row says forms.ex's style-less `Projection.project/3` "writes
  content[body][html] on the email surface and undoes #15973 for Classic-form
  saves". **It does not.** `Content.upsert_document/4` runs
  `Content.Writer.maybe_project_document_content/2` on the SAME write, which
  re-projects `content["body"]` (and every bound field) from
  `content["blocks"]` through `doc_render_opts/3` — the helper #15973 fixed. So
  forms.ex's projection is UNCONDITIONALLY OVERWRITTEN before anything is
  persisted, and no Classic save was ever storing email HTML on current main.

  Two mutations pin that, both pasted in PR #16047:

    * revert the `forms.ex` hunk alone, this test stays **GREEN** (`1 test, 0
      failures`) — the site is not the last writer;
    * keep forms.ex fixed and revert *writer.ex*'s `Map.put(:style, :article)`
      instead, and this test **REDS** on `refute stored_html =~ "font-family:"`
      — writer.ex is what supplies the surface.

  The forms.ex hunk still lands, for the reason criterion 0 asks for: the site
  must NAME its surface rather than let `Render.render_block/2`'s
  `Map.get(opts, :style, :email)` default pick one. It is defence in depth
  against a future write path that skips writer.ex's re-projection — it is not
  the fix for a live defect, and this file does not claim it is.

  ## What this test IS a guard for

  The end-to-end invariant: a Classic form save of a block-bearing document
  persists `content["body"]["html"]` stamp-free and byte-equal to the
  `:article` render. It reds if EITHER layer regresses (mutation two above),
  which is the guard that matters to a reader.

  `BulldocsEmailController.show/2` (bulldocs_email_controller.ex) — the one caller that genuinely wants
  `:email` — names it itself and re-renders from blocks; it is untouched by
  this row, as is `api/lib/barkpark/portable_doc/render.ex`.

  ## The anti-vacuity guard

  `refute stored_html == email_html` + `assert email_html =~ "font-size:17px"`:
  before the `:email` paragraph stamp (#15461/#15973) the `:article` and
  `:email` renders of a plain paragraph were the SAME bytes, which is why this
  defect hid. Without those lines the equality below could pass vacuously over
  a still-broken projection.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Projection
  alias Barkpark.PortableDoc.Render

  @dataset "production"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "slug"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "slug"},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    :ok
  end

  defp schema_for do
    {:ok, schema} = Content.get_schema("post", @dataset)
    schema
  end

  test "a Classic save re-projects content[body][html] onto the ARTICLE surface" do
    id = "classic-render-surface-#{System.unique_integer([:positive])}"

    free = [
      %{
        "id" => "free1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "classic body copy, no mail type"}]
      }
    ]

    blocks =
      [
        %{"id" => "b-title", "type" => "field", "fieldName" => "title", "value" => "Original"}
        | free
      ]

    content = Projection.project(%{"blocks" => blocks}, blocks, %{style: :article})

    {:ok, base_doc} =
      Content.upsert_document(
        "post",
        %{"doc_id" => id, "title" => "Original", "content" => content},
        @dataset
      )

    # The fixture's own non-vacuity check: the blocks branch of
    # `classic_save_content/4` is the one under test, so the base doc MUST
    # carry a block list (the legacy `_ ->` branch never projects at all).
    assert is_list(base_doc.content["blocks"])

    form = %{"title" => "Updated", "slug" => "", "status" => "draft"}
    {:ok, saved, _errs} = Content.upsert_draft(base_doc, "post", schema_for(), form, @dataset)

    stored_html = get_in(saved.content, ["body", "html"])
    article_html = Render.render_blocks(free, %{style: :article})
    email_html = Render.render_blocks(free, %{style: :email})

    # 1. Not one byte of the `:email` paragraph stamp is persisted.
    refute stored_html =~ "font-family:"
    refute stored_html =~ "font-size:"
    refute stored_html =~ "line-height:"
    refute stored_html =~ "style="

    # 2. It is the ARTICLE render, byte-exact.
    assert stored_html == article_html

    # 3. ANTI-VACUITY (see @moduledoc): the two surfaces really do differ for
    #    this very block, so assertion 2 is a CHOICE of surface.
    refute stored_html == email_html
    assert email_html =~ "font-size:17px"
  end
end
