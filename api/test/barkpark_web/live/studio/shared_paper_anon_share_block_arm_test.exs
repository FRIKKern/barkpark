defmodule BarkparkWeb.Studio.SharedPaperAnonShareBlockArmTest do
  @moduledoc """
  task-e175d91d93291b10 — the BLOCK-PATH TWIN of #14599 / PR #15084.

  #15084 clamped the HTML arm. This is the other half: when
  `Projection.read_blocks/1` returns a LIST, the same anonymous `:docs`-share
  viewer takes the BLOCK path instead, and every block on it came straight off
  `%Content.Document{}`:

    * `Shared.Paper.paper_stream_items/3` renders `content["blocks"]` raw into
      the `:paper_blocks` stream (the canvas-OFF View arm),
    * `Handlers.Lifecycle.paper_block/2` paints a delta frame's writer-rendered
      html into that same stream, and
    * `components.ex` computes `edit_blocks` from `paper_doc.content["blocks"]`
      raw and shows the canvas editor whenever `paper_block_mode` is true —
      the mainline default.

  No `Envelope.render`, no visibility redaction — so a paper whose block body
  the reader REFUSES (`{:error, :redacted_source}`: a structured source existed
  and visibility removed it) still painted its blocks in full.

  THE FIX MOVES THE SOURCE, NOT THE SURFACE. `paper_block_mode` now follows
  `Shared.Paper.reader_paper_blocks/2`, so a refusal means there is nothing to
  stream AND nothing to edit — the never-blank notice is the surface for that
  state, and the editor is absent because the body is, not because this row
  hides it. Gating the editor itself was tried and REVERTED: it reds the
  non-vacuity guard of `pds_w43_caps_readonly_share_test.exs` and
  `pds_w42_paper_op_principal_gate_test.exs` (6 failures), which drive that very
  editor to prove the SERVER refuses the write — the P4 ruling this repo already
  made ("the write boundary must be the SERVER's event handler, not hidden
  buttons").

  Because a redacted paper keeps its raw `blocks` list, `paper_block_mode` is
  true for it and `:redacted_source` is reachable ONLY through this arm — which
  is why the redaction leg of task-fa27740cb3162dbd is really this row.

  THE RULE IS #15084's, UNCHANGED: `write_denied?/1` (→ `Caps.write_capable?/2`)
  decides, `Content.Papers.reader_source/3` answers, no second sanitizer. A
  write-capable socket keeps the raw editor view.

  ITS OWN DATASET, DELIBERATELY (the lesson from #15084's CI red): schema
  resolution matches "this workspace OR global" and breaks ties on `dataset_id`
  alone, so a foreign global `paper` schema sharing the dataset can win on the
  one shared test database. A dataset no other file names cannot be raced.

  `async: false` — the `:shares` registry and the paper-canvas flag are
  process-global.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Sharing}

  @dataset "anon-block-arm-#{System.unique_integer([:positive])}"
  @prose "Board minutes: the acquisition price is 42M"

  setup %{conn: conn} do
    prev_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    prior_shares = Application.get_env(:barkpark, :shares)

    # The canvas default, pinned: canvas-ON is the posture in which
    # `show_editor` is true for a block paper, i.e. the one that hands an
    # anonymous viewer the editor buffer. A canvas-OFF run would exercise the
    # streamed View arm only and half the defect would go unmeasured.
    System.delete_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev_canvas do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end

      if is_nil(prior_shares),
        do: Application.delete_env(:barkpark, :shares),
        else: Application.put_env(:barkpark, :shares, prior_shares)
    end)

    # A NON-default workspace: the Default workspace is an open public-demo in
    # test and that arm is offered BEFORE the share arm, so a share on Default
    # never produces the `:share_read` grade.
    ws = create_workspace!("anon-block-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "anon-block-proj")

    Application.put_env(
      :barkpark,
      :shares,
      Sharing.parse("#{ws.slug}/#{proj.slug}/#{@dataset}:docs:read")
    )

    seed_paper_schema!(ws, proj, false)
    # The publish wall reads THIS dataset's tag registry (see the sibling file).
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, conn: conn, ws: ws, proj: proj}
  end

  # The tenant's `paper` schema. `private?` flips the `blocks` FIELD private,
  # which is what makes `Envelope.render` drop the structured body and
  # `reader_source/3` answer `{:error, :redacted_source}` — the same lever
  # `test/barkpark/content/papers_reader_source_test.exs` pulls.
  defp seed_paper_schema!(ws, proj, private?) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "blocks", "title" => "Blocks", "type" => "array", "private" => private?}
          ]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )
  end

  defp create_block_paper!(ws, proj, slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "Minutes"},
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => @prose}]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "title" => "Minutes",
          "dataset" => @dataset,
          "blocks" => blocks,
          "workspace_id" => ws.id,
          "project_id" => proj.id
        })
      )

    paper
  end

  defp open_paper!(conn, ws, proj, slug) do
    {:ok, _view, html} =
      live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

    html
  end

  describe "an anonymous :docs-share viewer on a block-backed paper" do
    test "CONTROL: a public block body IS rendered (the fixture is not vacuous)",
         %{conn: conn, ws: ws, proj: proj} do
      slug = "anon-block-public-#{System.unique_integer([:positive])}"
      paper = create_block_paper!(ws, proj, slug)

      assert {:blocks, _} =
               Content.Papers.reader_source(paper, @dataset,
                 workspace_id: ws.id,
                 project_id: proj.id
               )

      html = open_paper!(conn, ws, proj, slug)
      assert html =~ "studio-paper-editor"
      assert html =~ @prose

      # NOT asserted here: that the editor is absent. `LiveScope`'s P4 ruling is
      # explicit that a `:docs` read share opens the FULL Studio UI and that the
      # write boundary is the SERVER's event handler, "not hidden buttons" —
      # `pds_w43_caps_readonly_share_test.exs` and
      # `pds_w42_paper_op_principal_gate_test.exs` DRIVE that editor to prove the
      # refusal, and gating it away reds their non-vacuity guard (measured: 6
      # failures). So this row moves the SOURCE the surface reads, never the
      # surface a read-only viewer is allowed to see.
    end

    test "a REDACTED block body never reaches the viewer — raw blocks are not the source",
         %{conn: conn, ws: ws, proj: proj} do
      seed_paper_schema!(ws, proj, true)
      slug = "anon-block-redacted-#{System.unique_integer([:positive])}"
      paper = create_block_paper!(ws, proj, slug)

      # The verdict this surface OWES the viewer: the reader refuses to name a
      # source, because a structured body existed and visibility removed it.
      assert {:error, :redacted_source} =
               Content.Papers.reader_source(paper, @dataset,
                 workspace_id: ws.id,
                 project_id: proj.id
               )

      html = open_paper!(conn, ws, proj, slug)

      # The pane opened (not a redirect, not an empty desk) ...
      assert html =~ "studio-paper-editor"
      # ... and the redacted prose is nowhere in it — not in the streamed View
      # arm and not in the canvas editor's buffer.
      refute html =~ @prose
    end

    test "a delta frame cannot paint bytes the reader never produced",
         %{conn: conn, ws: ws, proj: proj} do
      # THE CANVAS-OFF OPT-OUT, deliberately: `apply_paper_delta/2` paints into
      # the `:paper_blocks` STREAM, and the stream is only rendered by the
      # read-only View arm — which is the surface exactly when the canvas is
      # off. With the canvas on, a block paper renders the editor instead and a
      # frame's html never reaches the DOM, so a canvas-on assertion here would
      # pass vacuously (measured: removing the guard left it green).
      System.put_env("BARKPARK_PAPER_CANVAS", "0")

      slug = "anon-block-delta-#{System.unique_integer([:positive])}"
      paper = create_block_paper!(ws, proj, slug)

      {:ok, view, html} =
        live(conn, "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/paper/#{slug}")

      assert html =~ @prose
      rev = (paper.content["rev"] || 0) + 1

      # `{:paper_block, …}` carries a block's html rendered in the WRITER's
      # process, under the WRITER's scope and resolvers. For a viewer that is an
      # unclamped feed one frame at a time, so it is advisory here too.
      send(
        view.pid,
        {:paper_block,
         %{
           block_id: "body",
           fragment_html: "<p>INJECTED-BY-FRAME</p>",
           rev: rev,
           op_kind: :replace
         }}
      )

      rendered = render(view)
      refute rendered =~ "INJECTED-BY-FRAME"
      assert rendered =~ @prose
    end

    test "the refusal renders the honest notice, not the blocks and not an editor",
         %{conn: conn, ws: ws, proj: proj} do
      seed_paper_schema!(ws, proj, true)
      slug = "anon-block-notice-#{System.unique_integer([:positive])}"
      _paper = create_block_paper!(ws, proj, slug)

      html = open_paper!(conn, ws, proj, slug)

      assert html =~ "paper-unrenderable-notice"
      refute html =~ @prose
      # No editor either — not because this row hides one, but because the
      # reader refused the source, so `paper_block_mode` is false and there is
      # nothing to edit. The notice IS the surface for that state.
      refute html =~ ~s(data-test-id="studio-paper-block-editor")
    end
  end
end
