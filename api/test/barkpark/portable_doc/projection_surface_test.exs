defmodule Barkpark.PortableDoc.ProjectionSurfaceTest do
  @moduledoc """
  task-605ba8bfbd54c871 — the STORED projection is decoupled from EMAIL
  typography.

  The canonical `content["body"]["html"]` on every document used to be rendered
  with the `:email` surface, because nothing on the write path named a surface
  and `Render.render_block/2`'s default is `:email`. The row's census found zero
  readers that wanted email HTML there; the one consumer that does
  (`bulldocs_email_controller.ex`) names `:email` itself and re-renders from
  blocks. `Content.Writer.doc_render_opts/3` now sets `:style, :article`.

  This test is the REGRESSION PROOF for that property: a change to EMAIL
  paragraph typography must leave the stored projection byte-identical. It goes
  through a REAL `Content.create_document/4` write, so it pins what is actually
  PERSISTED, not merely what the renderer would emit if asked nicely.

  ## The anti-vacuity guard

  `refute stored_html == email_html` is not decoration. On main BEFORE the
  `:email` paragraph stamp (PR #15461, adopted in this same PR), the `:article`
  and `:email` renders of a plain paragraph were the SAME bytes —
  `<p>the quick brown fox</p>` either way — which is exactly why this defect
  hid for so long. Delete the `refute` and the test would have passed vacuously
  on pre-stamp main while the write path was still rendering email HTML. The
  guard is only SATISFIABLE because the stamp ships in this PR, and it is what
  makes the `assert` above it mean something.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Render

  @dataset "production"

  setup do
    # A schema with an explicit Expectation layout carrying a `body` REGION —
    # the gate for create_document/4's portable-doc scaffold path, i.e. the only
    # shape that reaches Projection.project/4 and therefore doc_render_opts/3.
    #
    # The NAME IS UNIQUE PER TEST, deliberately. `schema_definitions` is keyed
    # on (name, dataset), so an `async: true` module that upserts the shared
    # "post" row contends with the ~40 other test files that also write it —
    # observed here as a live `40P01 deadlock_detected` during the mutation
    # run, on a box where several agents share one test database. A unique
    # name means this module never takes a lock anyone else wants.
    type = "surfacepost#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "text"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title", "max" => 1, "enforce" => true},
            %{"kind" => "region", "name" => "body"}
          ]
        },
        @dataset
      )

    {:ok, type: type}
  end

  describe "the stored body projection is rendered on the :article surface" do
    test "a plain paragraph stores the ARTICLE bytes, and the two surfaces differ", %{
      type: type
    } do
      doc_id = "surface-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.create_document(
          type,
          %{
            "doc_id" => doc_id,
            "title" => "Hello world",
            "content" => %{"body" => "the quick brown fox"}
          },
          @dataset
        )

      stored_blocks = doc.content["body"]["blocks"]
      stored_html = doc.content["body"]["html"]

      article_html = Render.render_blocks(stored_blocks, %{style: :article})
      email_html = Render.render_blocks(stored_blocks, %{style: :email})

      # 1. The write path stores the ARTICLE render, byte-exact. `:article`'s
      #    `<p>` is bare BY CONTRACT — `.bp-paper-surface p` is the single
      #    source of body typography in View and Edit — which is why this is
      #    also the value studio_live_editor_test.exs:198 has always pinned.
      assert stored_html == article_html
      assert stored_html == "<p>the quick brown fox</p>"

      # 2. THE ANTI-VACUITY GUARD (see @moduledoc). The two surfaces are
      #    OBSERVABLY different for the very same block, so assertion 1 is a
      #    real choice of surface and not a coincidence of two renders that
      #    happen to agree. This is only satisfiable because the `:email`
      #    paragraph stamp ships in this PR; on pre-stamp main both sides were
      #    `<p>the quick brown fox</p>` and deleting this line would leave a
      #    green test over a broken write path.
      refute stored_html == email_html
      assert email_html =~ "font-size:17px"
    end

    test "moving EMAIL paragraph typography leaves the stored projection alone", %{type: type} do
      doc_id = "surface-decoupled-#{System.unique_integer([:positive])}"

      {:ok, doc} =
        Content.create_document(
          type,
          %{
            "doc_id" => doc_id,
            "title" => "Decoupled",
            "content" => %{"body" => "body copy that must not carry mail type"}
          },
          @dataset
        )

      stored_html = doc.content["body"]["html"]

      # The property the row exists for, stated negatively: not one byte of the
      # email surface's inline stamp may appear in what is PERSISTED. Each of
      # these declarations is emitted by Walk.body_type/2 on the `:email` leg;
      # if the write path ever falls back to the `:email` default again, every
      # one of them reappears here.
      refute stored_html =~ "font-family:"
      refute stored_html =~ "font-size:"
      refute stored_html =~ "line-height:"
      refute stored_html =~ "margin:"
      refute stored_html =~ "style="
    end
  end
end
