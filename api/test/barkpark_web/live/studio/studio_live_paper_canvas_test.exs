defmodule BarkparkWeb.Studio.StudioLivePaperCanvasTest do
  @moduledoc """
  Phase-4 S2 — wire `<bp-paper-canvas>` into the Studio paper editor behind the
  BARKPARK_PAPER_CANVAS flag. The contract proven here:

    1. FLAG-OFF BYTE-IDENTICAL (the critical test): with the flag unset, the
       rendered editor HTML is EXACTLY today's per-block render — the same
       `paper-ed-<id>` rich-text wrappers, NO `<bp-paper-canvas>`. The flag-OFF
       output is snapshotted to disk on the first run and diffed on every run
       (so any future drift in the OFF path fails loudly).

    2. FLAG-ON render: as of S3.2 the callout is canvas-eligible, so a
       [heading, paragraph, callout, paragraph, divider] paper renders ONE
       `<bp-paper-canvas>` run containing the callout INLINE (no separate per-block
       callout widget), with the data-expected-fields carrier OUTSIDE every
       phx-update="ignore" wrapper.

    3. paper-ops HANDLER: a small ops array pushed as `paper-ops` folds through
       Content.apply_paper_block_ops (Patch.apply_patches) and persists IDENTICALLY
       to the per-block path — canvas ops are just a batch of the same ops.

  The flag is per-process env; each flag-ON test sets + restores it. The OFF
  tests rely on the unset default (the suite's baseline).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  @dataset "production"
  @slug "2026-06-23-canvas-paper"

  @snapshot_path Path.join(__DIR__, "snapshots/paper_editor_flag_off.html")

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  # A representative paper: heading + paragraph + callout + paragraph + divider.
  # As of S3.2 ALL FIVE are canvas-eligible (prose ∪ callout ∪ divider), so flag-ON
  # they form ONE maximal run. Flag-OFF they each render per-block (the snapshot
  # baseline). Stable ids so the snapshot is deterministic.
  defp seed_canvas_paper! do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "Canvas Paper", "level" => 1},
      %{
        "id" => "p-intro",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "First run, paragraph one."}]
      },
      %{
        "id" => "c-note",
        "type" => "callout",
        "tone" => "info",
        "content" => [%{"type" => "text", "value" => "A boundary callout."}]
      },
      %{
        "id" => "p-after",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Second run, paragraph two."}]
      },
      %{"id" => "d-end", "type" => "divider"}
    ]

    {:ok, paper} = Content.upsert_paper(%{slug: @slug, dataset: @dataset, blocks: blocks})
    paper
  end

  setup do
    seed_paper_schema!()
    seed_canvas_paper!()
    :ok
  end

  defp open_editor(view) do
    html = view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()
    assert html =~ ~s(data-test-id="studio-paper-block-editor")
    html
  end

  # Slice just the editor surface so the snapshot is stable against unrelated
  # chrome (header buttons carry tokens / counts that drift across runs).
  defp editor_html(html) do
    [_, slice] =
      Regex.run(
        ~r/(<div id="paper-editor-#{Regex.escape(@slug)}".*?<\/footer>\s*<\/div>)/s,
        html
      )

    slice
  end

  # ── 1. FLAG-OFF BYTE-IDENTICAL (the critical test) ──────────────────────────

  test "flag OFF: editor renders the per-block path with NO <bp-paper-canvas>",
       %{conn: conn} do
    # The flag is unset in the suite baseline (ConnCase doesn't set it). Sanity-
    # guard so a leaked env from another test can't silently pass this.
    refute System.get_env("BARKPARK_PAPER_CANVAS") in ["1", "true"]

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    edit_html = open_editor(view)

    # The per-block rich-text wrappers are present; the canvas is NOT.
    assert edit_html =~ ~s(id="paper-ed-h-1")
    assert edit_html =~ ~s(id="paper-ed-p-intro")
    assert edit_html =~ ~s(phx-hook="BarkparkPaperEditor")
    assert edit_html =~ ~s(<bp-paper-editor)
    refute edit_html =~ ~s(<bp-paper-canvas)
    refute edit_html =~ ~s(phx-hook="BarkparkPaperCanvas")
    refute edit_html =~ ~s(data-test-id="paper-canvas-run")

    # The callout still renders via its existing per-block form (a run boundary
    # in the ON path, but here just a normal per-block widget).
    assert edit_html =~ ~s(data-edit-block-id="c-note")
  end

  test "flag OFF render is BYTE-IDENTICAL to the stored snapshot (no OFF-path drift)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    rendered = editor_html(open_editor(view))

    if File.exists?(@snapshot_path) do
      baseline = File.read!(@snapshot_path)

      assert rendered == baseline, """
      FLAG-OFF render drifted from the committed snapshot. The per-block (OFF)
      path must stay byte-identical. If this change is intentional, delete
      #{@snapshot_path} and re-run to re-baseline.
      """
    else
      File.mkdir_p!(Path.dirname(@snapshot_path))
      File.write!(@snapshot_path, rendered)

      flunk("""
      Wrote the flag-OFF snapshot baseline to #{@snapshot_path}.
      Re-run the suite to assert byte-identity against it.
      """)
    end
  end

  # ── 2. FLAG-ON render ───────────────────────────────────────────────────────

  describe "flag ON" do
    setup do
      prev = System.get_env("BARKPARK_PAPER_CANVAS")
      System.put_env("BARKPARK_PAPER_CANVAS", "1")

      on_exit(fn ->
        case prev do
          nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
          v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
        end
      end)

      :ok
    end

    test "renders ONE <bp-paper-canvas> run containing the callout INLINE (no per-block callout widget)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      edit_html = open_editor(view)

      # As of S3.2 the callout is canvas-eligible, so the whole seed
      # [heading, paragraph, callout, paragraph, divider] is ONE maximal run, KEYED
      # by the run's first block id (h-1).
      assert edit_html =~ ~s(id="paper-canvas-h-1")
      assert edit_html =~ ~s(phx-hook="BarkparkPaperCanvas")
      assert edit_html =~ ~s(phx-update="ignore")
      assert edit_html =~ ~s(<bp-paper-canvas)

      # Exactly ONE canvas wrapper — neither the callout nor the divider splits it.
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, edit_html)) == 1

      # S3.2: the callout is INSIDE the canvas now, NOT a standalone per-block
      # widget — so its edit-block wrapper must be ABSENT (it rides the run's
      # data-canvas-blocks carrier instead).
      refute edit_html =~ ~s(data-edit-block-id="c-note")
      refute edit_html =~ ~s(data-block-type="callout")

      # S3: the divider likewise rides the run, NOT a standalone widget.
      refute edit_html =~ ~s(data-edit-block-id="d-end")

      # The per-block <bp-paper-editor> WC is NOT used on the ON path — the prose
      # blocks live inside the canvas instead.
      refute edit_html =~ ~s(id="paper-ed-h-1")
      refute edit_html =~ ~s(<bp-paper-editor)

      # The run carries its blocks on data-canvas-blocks (Jason-encoded). The
      # callout's id rides that carrier (it is a member of the single run).
      assert edit_html =~ "data-canvas-blocks"
      assert edit_html =~ "c-note"
    end

    test "canvas is GATED to the paper pane — absent when canvas_eligible is false (the Beta document-editor default)" do
      blocks = [
        %{"id" => "h-1", "type" => "heading", "text" => "Doc", "level" => 1},
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "body"}]
        }
      ]

      base = [slug: "doc-1", blocks: blocks, paper_rev: 0, dataset: @dataset, api_token_raw: ""]

      # The Beta per-document editor leaves canvas_eligible at its FALSE default,
      # so even with the flag ON the canvas must NOT mount there (its paper-ops
      # would persist to the wrong doc). The paper pane passes true → canvas mounts.
      not_eligible =
        render_component(&PaperEditor.paper_block_editor/1, base ++ [canvas_eligible: false])

      eligible =
        render_component(&PaperEditor.paper_block_editor/1, base ++ [canvas_eligible: true])

      refute not_eligible =~ ~s(<bp-paper-canvas)
      assert not_eligible =~ ~s(id="paper-ed-h-1")
      assert eligible =~ ~s(<bp-paper-canvas)
    end

    test "the data-expected-fields carrier stays OUTSIDE every phx-update=ignore wrapper",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      edit_html = open_editor(view)

      # The carrier exists once, and it is NOT inside any canvas wrapper. Assert
      # the carrier appears BEFORE the first canvas wrapper in source order (it is
      # rendered at the top of the editor body, above the partitioned runs), so it
      # cannot be nested inside a phx-update="ignore" canvas.
      carrier_at = :binary.match(edit_html, ~s(id="bp-expected-fields")) |> elem(0)
      first_canvas_at = :binary.match(edit_html, ~s(id="paper-canvas-h-1")) |> elem(0)
      assert carrier_at < first_canvas_at
    end

    test "S3: a divider trailing a run rides that run's canvas (NOT its own boundary widget)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      edit_html = open_editor(view)

      # The seed's trailing divider (d-end) joins the single S3.2 run. It is NOT a
      # standalone per-block widget — its edit-block wrapper is gone.
      refute edit_html =~ ~s(data-edit-block-id="d-end")
      refute edit_html =~ ~s(data-block-type="divider")

      # Instead it rides the run's data-canvas-blocks carrier (Jason-encoded, so
      # its id appears inside the canvas wrapper's attribute).
      assert edit_html =~ "d-end"
    end

    test "S3.2: [paragraph, callout, paragraph] renders ONE canvas run containing the callout" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "before"}]
        },
        %{
          "id" => "c-1",
          "type" => "callout",
          "tone" => "warning",
          "content" => [%{"type" => "text", "value" => "watch out"}]
        },
        %{
          "id" => "p-2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-callout",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # ONE <bp-paper-canvas> run keyed by the run's first block (p-1) — the callout
      # does NOT split it into two canvases with a per-block widget between.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-p-1")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The callout is NOT rendered as a separate per-block widget — it lives
      # INSIDE the single run (no edit-block wrapper, no per-block callout form).
      refute html =~ ~s(data-edit-block-id="c-1")
      refute html =~ ~s(data-block-type="callout")
      refute html =~ ~s(id="paper-ed-p-1")

      # The callout rides the run's data-canvas-blocks carrier (its id + tone are
      # in the Jason-encoded block list on the canvas wrapper).
      assert html =~ "c-1"
      assert html =~ "warning"
    end

    test "S3: [heading, divider, paragraph] renders ONE canvas run containing the divider" do
      blocks = [
        %{"id" => "h-1", "type" => "heading", "text" => "Doc", "level" => 1},
        %{"id" => "d-1", "type" => "divider"},
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "body"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-div",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # ONE <bp-paper-canvas> run keyed by the run's first block (the heading) —
      # the divider does NOT split it into two canvases with a widget between.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-h-1")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The divider is NOT rendered as a separate per-block widget between two
      # canvases — it lives INSIDE the single run.
      refute html =~ ~s(data-edit-block-id="d-1")
      refute html =~ ~s(id="paper-ed-h-1")

      # The divider rides the run's data-canvas-blocks carrier (its id is in the
      # Jason-encoded block list on the canvas wrapper).
      assert html =~ "d-1"
    end

    test "S3.3: [paragraph, code, paragraph] renders ONE canvas run containing the code" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "before"}]
        },
        %{"id" => "k-1", "type" => "code", "lang" => "elixir", "value" => "IO.puts(:ok)"},
        %{
          "id" => "p-2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-code",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # ONE <bp-paper-canvas> run keyed by the run's first block (p-1) — the code
      # block does NOT split it into two canvases with a per-block widget between.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-p-1")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The code block is NOT rendered as a separate per-block widget — it lives
      # INSIDE the single run (no edit-block wrapper, no per-block code form).
      refute html =~ ~s(data-edit-block-id="k-1")
      refute html =~ ~s(data-block-type="code")
      refute html =~ ~s(id="paper-ed-p-1")

      # The code rides the run's data-canvas-blocks carrier (its id + value + lang
      # are in the Jason-encoded block list on the canvas wrapper).
      assert html =~ "k-1"
      assert html =~ "IO.puts(:ok)"
      assert html =~ "elixir"
    end

    test "S3.4: [paragraph, diagram, paragraph] renders ONE canvas run containing the diagram" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "before"}]
        },
        %{
          "id" => "g-1",
          "type" => "diagram",
          "source" => "graph TD\n  A-->B",
          "caption" => "Figure 1."
        },
        %{
          "id" => "p-2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-diagram",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # ONE <bp-paper-canvas> run keyed by the run's first block (p-1) — the diagram
      # block does NOT split it into two canvases with a per-block widget between.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-p-1")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The diagram block is NOT rendered as a separate per-block widget — it lives
      # INSIDE the single run (no edit-block wrapper, no per-block diagram form).
      refute html =~ ~s(data-edit-block-id="g-1")
      refute html =~ ~s(data-block-type="diagram")
      refute html =~ ~s(id="paper-ed-p-1")

      # The diagram rides the run's data-canvas-blocks carrier (its id + source +
      # caption are in the Jason-encoded block list on the canvas wrapper).
      assert html =~ "g-1"
      assert html =~ "graph TD"
      assert html =~ "Figure 1."
    end

    test "S3.5: [paragraph, field-string, paragraph] renders ONE canvas run containing the field" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "before"}]
        },
        %{
          "id" => "fld-1",
          "type" => "field-string",
          "label" => "Title",
          "fieldName" => "title",
          "value" => "Hello"
        },
        %{
          "id" => "p-2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-field",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # ONE <bp-paper-canvas> run keyed by the run's first block (p-1) — the native
      # field-string does NOT split it into two canvases with a per-block widget.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-p-1")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The field is NOT rendered as a separate per-block widget — it lives INSIDE
      # the single run (no edit-block wrapper, no per-block field control with the
      # BarkparkFieldBlockBridge hook).
      refute html =~ ~s(data-edit-block-id="fld-1")
      refute html =~ ~s(phx-hook="BarkparkFieldBlockBridge")
      refute html =~ ~s(id="paper-ed-p-1")

      # The field rides the run's data-canvas-blocks carrier (its id + value +
      # fieldName are in the Jason-encoded block list on the canvas wrapper).
      assert html =~ "fld-1"
      assert html =~ "Hello"
      assert html =~ "title"
    end

    test "S3.5: [paragraph, field-image, paragraph] — the field-image is STILL a boundary widget (NOT in the canvas)" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "before"}]
        },
        %{
          "id" => "img-1",
          "type" => "field-image",
          "label" => "Hero",
          "value" => ""
        },
        %{
          "id" => "p-2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-field-image",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # The field-image (a PICKER) STILL splits the run: it is its OWN per-block
      # boundary widget, NOT inside the canvas. So TWO canvas runs flank it (p-1 and
      # p-2 each on their own), and the field-image keeps its per-block edit wrapper
      # mounted with the BarkparkFieldBlockBridge hook.
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 2
      assert html =~ ~s(id="paper-canvas-p-1")
      assert html =~ ~s(id="paper-canvas-p-2")

      # The field-image is a standalone per-block widget — its edit-block wrapper is
      # present and it carries the per-block bridge hook + its picker WC.
      assert html =~ ~s(data-edit-block-id="img-1")
      assert html =~ ~s(phx-hook="BarkparkFieldBlockBridge")
    end

    test "S3.6: [paragraph, sheet, paragraph] renders ONE canvas run containing the (read-only) sheet" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "before"}]
        },
        %{
          "id" => "sh-1",
          "type" => "sheet",
          "ref" => "production/budget",
          "snapshot" => %{"rows" => [["A", "B"], ["1", "2"]]}
        },
        %{
          "id" => "p-2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-sheet",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # ONE <bp-paper-canvas> run keyed by the run's first block (p-1) — as of S3.6 the
      # sheet is a READ-ONLY atom that rides the run, NOT a boundary widget between two
      # canvases.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-p-1")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The sheet is NOT a separate per-block widget — it lives INSIDE the single run
      # (no edit-block wrapper, no per-block sheet form).
      refute html =~ ~s(data-edit-block-id="sh-1")
      refute html =~ ~s(data-block-type="sheet")
      refute html =~ ~s(id="paper-ed-p-1")

      # The sheet rides the run's data-canvas-blocks carrier VERBATIM (its id + ref +
      # snapshot are in the Jason-encoded block list on the canvas wrapper), so the
      # read-only atom round-trips the whole block.
      assert html =~ "sh-1"
      assert html =~ "production/budget"
    end

    # ── S4a: the ECHO push_event ────────────────────────────────────────────
    #
    # After apply_paper_block_ops persists a batch, paper_ops/2 re-reads the paper
    # and pushes `bp:canvas-update` carrying the CONFIRMED blocks, partitioned into
    # prose runs keyed by first-block id ("paper-canvas-"<>id). The canvas hook
    # routes each run to its <bp-paper-canvas> and calls applyServerBlocks — an
    # own-echo resets the baseline (no caret move), an external edit re-renders.
    test "S4a: a paper-ops batch pushes bp:canvas-update with the confirmed run blocks (flag ON)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      open_editor(view)

      # The seed [heading, paragraph, callout, paragraph, divider] is ONE maximal
      # run keyed by its first block id (h-1). Edit the intro paragraph.
      render_hook(view, "paper-ops", %{
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-intro",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Echoed back."}]}
          }
        ]
      })

      # ONE bp:canvas-update push carrying ONE run (the whole seed is a single run),
      # keyed by the first block id, carrying the CONFIRMED post-apply blocks —
      # including the edit we just made (the echo the canvas resets its baseline to).
      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: "h-1", blocks: blocks}] = runs

      # The run blocks are the confirmed blocks IN ORDER, edit applied.
      assert Enum.map(blocks, & &1["id"]) == ["h-1", "p-intro", "c-note", "p-after", "d-end"]

      intro = Enum.find(blocks, &(&1["id"] == "p-intro"))
      assert intro["content"] == [%{"type" => "text", "value" => "Echoed back."}]
    end

    test "S4a: a batch spanning TWO runs (a picker field splits them) pushes ONE entry per run",
         %{conn: conn} do
      # A paper whose field-image PICKER splits two prose runs. partition_runs →
      # [{:run,[p-a]}, {:block, img}, {:run,[p-b]}], so the echo carries TWO runs
      # (the boundary block has no canvas to update).
      split_slug = "2026-06-23-canvas-split"

      blocks = [
        %{
          "id" => "p-a",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "run one"}]
        },
        %{"id" => "img-1", "type" => "field-image", "label" => "Hero", "value" => ""},
        %{
          "id" => "p-b",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "run two"}]
        }
      ]

      {:ok, _} = Content.upsert_paper(%{slug: split_slug, dataset: @dataset, blocks: blocks})

      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{split_slug}"))

      open_editor(view)

      render_hook(view, "paper-ops", %{
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-b",
            "patch" => %{"content" => [%{"type" => "text", "value" => "run two edited"}]}
          }
        ]
      })

      assert_push_event(view, "bp:canvas-update", %{runs: runs})

      # TWO runs (the field-image boundary is NOT echoed — it has no canvas),
      # keyed by each run's first block id.
      assert [%{run_id: "p-a", blocks: run_a}, %{run_id: "p-b", blocks: run_b}] = runs
      assert Enum.map(run_a, & &1["id"]) == ["p-a"]
      assert Enum.map(run_b, & &1["id"]) == ["p-b"]

      # The echoed p-b run carries the confirmed edit.
      assert hd(run_b)["content"] == [%{"type" => "text", "value" => "run two edited"}]
    end

    test "S3.6: [paragraph, embed, paragraph] renders ONE canvas run containing the (read-only) embed" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "before"}]
        },
        %{"id" => "em-1", "type" => "embed", "target" => "Linked Note"},
        %{
          "id" => "p-2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-embed",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # ONE <bp-paper-canvas> run keyed by the run's first block (p-1) — the embed is a
      # READ-ONLY atom that rides the run.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-p-1")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The embed is NOT a separate per-block widget — it lives INSIDE the single run.
      refute html =~ ~s(data-edit-block-id="em-1")
      refute html =~ ~s(data-block-type="embed")

      # The embed rides the run's data-canvas-blocks carrier VERBATIM (its id + target
      # are in the Jason-encoded block list on the canvas wrapper).
      assert html =~ "em-1"
      assert html =~ "Linked Note"
    end
  end

  # ── 3. paper-ops HANDLER ────────────────────────────────────────────────────

  test "paper-ops folds a batch through apply_patches + persists identically to per-block",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    pid_before = view.pid

    # A <bp-paper-canvas> run emits bp-canvas-ops {ops:[…]}; the hook forwards it
    # as `paper-ops`. Here: one patch-block editing the intro paragraph's text —
    # the SAME op shape the per-block path persists, just inside a batch array.
    render_hook(view, "paper-ops", %{
      "ops" => [
        %{
          "op" => "patch-block",
          "id" => "p-intro",
          "patch" => %{"content" => [%{"type" => "text", "value" => "Edited via canvas batch."}]}
        }
      ]
    })

    block = Content.paper_blocks(@slug, @dataset) |> Enum.find(&(&1["id"] == "p-intro"))
    assert block["type"] == "paragraph"
    assert block["content"] == [%{"type" => "text", "value" => "Edited via canvas batch."}]

    # No remount — the batch went through the canonical persist path.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)

    # S4a flag-OFF guard: with the canvas flag UNSET (the suite baseline), the
    # echo path pushes NOTHING — no <bp-paper-canvas> is mounted to receive it,
    # and push_canvas_echo/1 gates on paper_canvas_enabled?(). The flag-OFF path
    # stays byte-identical (no new push_event leaks into the per-block render).
    refute_push_event(view, "bp:canvas-update", %{}, 50)
  end

  test "paper-ops persists a MULTI-op batch atomically (matches apply_patches)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    ops = [
      %{
        "op" => "patch-block",
        "id" => "h-1",
        "patch" => %{"text" => "Canvas Paper (edited)"}
      },
      %{
        "op" => "append-block",
        "block" => %{
          "id" => "p-new",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "Appended in the same batch."}]
        }
      }
    ]

    render_hook(view, "paper-ops", %{"ops" => ops})

    blocks = Content.paper_blocks(@slug, @dataset)

    # Cross-check: the persisted blocks equal apply_patches over the seed blocks.
    seed = [
      %{"id" => "h-1", "type" => "heading", "text" => "Canvas Paper", "level" => 1},
      %{
        "id" => "p-intro",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "First run, paragraph one."}]
      },
      %{
        "id" => "c-note",
        "type" => "callout",
        "tone" => "info",
        "content" => [%{"type" => "text", "value" => "A boundary callout."}]
      },
      %{
        "id" => "p-after",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Second run, paragraph two."}]
      },
      %{"id" => "d-end", "type" => "divider"}
    ]

    {:ok, expected} = Barkpark.PortableDoc.Patch.apply_patches(seed, ops)
    assert blocks == expected

    heading = Enum.find(blocks, &(&1["id"] == "h-1"))
    assert heading["text"] == "Canvas Paper (edited)"
    assert List.last(blocks)["id"] == "p-new"
  end

  test "paper-ops with an empty / non-list batch is a quiet no-op (never writes/crashes)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    before = Content.paper_blocks(@slug, @dataset)
    pid_before = view.pid

    render_hook(view, "paper-ops", %{"ops" => []})
    render_hook(view, "paper-ops", %{"ops" => "not-a-list"})
    render_hook(view, "paper-ops", %{})

    assert Content.paper_blocks(@slug, @dataset) == before
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end
end
