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

  # Bug #1c (cross-paper transplant): run ids are SLUG-NAMESPACED so a
  # patch-navigation to another paper can never reuse a stale ignore wrapper.
  # This is the seed paper's first-run id as it rides the echo payload; the DOM
  # wrapper id prefixes it with "paper-canvas-".
  @run0_id "#{@slug}-run-0"

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

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: @slug, dataset: @dataset, blocks: blocks})
      )

    paper
  end

  setup do
    seed_paper_schema!()
    seed_canvas_paper!()
    :ok
  end

  defp open_editor(view) do
    # With the canvas the mainline default (D7/D9) there is NO View⇄Edit toggle —
    # opening a paper IS the editor, rendered directly on mount (rule 5). On the
    # flag-OFF opt-out path the toggle is present and must be clicked to reveal the
    # per-block editor. Handle both so every caller gets the editor HTML either way.
    html =
      if has_element?(view, ~s([data-test-id="paper-edit-toggle"])) do
        view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()
      else
        render(view)
      end

    assert html =~ ~s(data-test-id="studio-paper-block-editor")
    html
  end

  defp paper_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

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
  #
  # The canvas is the mainline default now (D7/D9), so the legacy per-block path is
  # an EXPLICIT opt-out (`BARKPARK_PAPER_CANVAS=0`). These tests pin that opt-out so
  # they keep proving the OFF path is byte-identical to legacy (D3), independent of
  # the flipped default.

  describe "flag OFF (explicit opt-out — BARKPARK_PAPER_CANVAS=0)" do
    setup do
      prev = System.get_env("BARKPARK_PAPER_CANVAS")
      System.put_env("BARKPARK_PAPER_CANVAS", "0")

      on_exit(fn ->
        case prev do
          nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
          v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
        end
      end)

      :ok
    end

    test "the opt-out path opens read-only and shows the View⇄Edit toggle (a mode still exists here)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

      # On the opt-out path a block paper opens in the READ-ONLY streamed View —
      # the toggle is present and the block editor is NOT yet rendered. (Key on
      # the real render marker `paper-canvas-<slug>-run-0`, NOT the bare
      # `<bp-paper-canvas` string — the latter also appears in the root layout's
      # JS hook comments.)
      assert html =~ ~s(data-test-id="paper-edit-toggle")
      assert html =~ ~s(phx-update="stream")
      refute html =~ ~s(data-test-id="studio-paper-block-editor")
      refute html =~ ~s(id="paper-canvas-#{@run0_id}")
      refute html =~ ~s(data-test-id="paper-canvas-run")
    end

    test "editor renders the per-block path with NO <bp-paper-canvas>", %{conn: conn} do
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

    test "render is BYTE-IDENTICAL to the stored snapshot (no OFF-path drift)",
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

    test "opening a paper IS the editor — the canvas mounts DIRECTLY on open, no View⇄Edit toggle (rule 5)",
         %{conn: conn} do
      # The whole point of the cutover: no click, no mode. The initial mount HTML
      # already carries the canvas editor and NO toggle button.
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

      # The editor is live on open… (key on the real render marker
      # `paper-canvas-<slug>-run-0` — the bare `<bp-paper-canvas` string also
      # appears in the root layout's JS hook comments, so it would assert
      # vacuously.)
      assert html =~ ~s(data-test-id="studio-paper-block-editor")
      assert html =~ ~s(data-test-id="paper-canvas-run")
      assert html =~ ~s(id="paper-canvas-#{@run0_id}")

      # …and the View⇄Edit toggle is GONE — there are no modes to be in.
      refute html =~ ~s(data-test-id="paper-edit-toggle")
      refute html =~ ~s(phx-click="paper-toggle-edit")

      # The read-only streamed View pane is NOT rendered — the body is the canvas,
      # not a per-block phx-update="stream" list.
      refute html =~ ~s(id="paper-body-#{@slug}")

      # The canvas region keeps an accessible name now that the toggle is gone.
      assert html =~ ~s(data-test-id="studio-paper-shell")
      assert html =~ ~s(aria-label="Editing )

      # The "Open standalone" reader link + the Share affordance survive the
      # toggle's removal — the header action row stays coherent.
      assert html =~ ~s(data-test-id="paper-open-standalone")
    end

    test "an external {:paper_block} delta re-syncs the edit doc and pushes the block to the WCs (no Edit mode needed)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

      # Another producer (the ingest endpoint / a second session) appends a
      # block through the real Content + PubSub spine — the {:paper_block}
      # frame arrives with sender != the LiveView pid.
      {:ok, _} =
        Content.apply_paper_block_op(
          @slug,
          %{
            "op" => "append-block",
            "block" => %{
              "id" => "p-ext",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Appended externally."}]
            }
          },
          @dataset
        )

      # Pre-t12b this sync was gated on `paper_edit_mode` — permanently false
      # with the toggle retired — so the mainline canvas path silently skipped
      # the edit-doc re-sync + WC push on external edits. The push proves BOTH
      # halves: push_block_to_wc finds "p-ext" only in a paper_doc that
      # sync_paper_edit_doc just re-read from the DB.
      assert_push_event(view, "bp:block-update", %{block_id: "p-ext"}, 500)

      # No remount — the delta was absorbed in place.
      assert render(view) =~ ~s(id="paper-sentinel")
    end

    test "an HTML-only legacy paper opens READ-ONLY: raw body, no canvas, no toggle, no 'Editing' label",
         %{conn: conn} do
      legacy_slug = "2026-06-23-legacy-html-paper"

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: legacy_slug,
            dataset: @dataset,
            body_html: "<p>Legacy body, nothing to edit.</p>"
          })
        )

      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{legacy_slug}"))

      # The raw body renders; there is no editor and no mode to toggle into —
      # a blockless paper has nothing to edit on EITHER path (rule 5 does not
      # invent an editor where no blocks exist).
      assert html =~ "Legacy body, nothing to edit."
      refute html =~ ~s(data-test-id="studio-paper-block-editor")
      refute html =~ ~s(id="paper-canvas-#{legacy_slug}-run-0")
      refute html =~ ~s(data-test-id="paper-edit-toggle")

      # The accessible name must NOT claim an editing surface here — the label
      # is gated on the editor actually being live, not on the flag alone.
      refute html =~ ~s(aria-label="Editing )
    end

    test "renders ONE <bp-paper-canvas> run containing the callout INLINE (no per-block callout widget)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      edit_html = open_editor(view)

      # As of S3.2 the callout is canvas-eligible, so the whole seed
      # [heading, paragraph, callout, paragraph, divider] is ONE maximal run, KEYED
      # by the slug + its ORDINAL (Bug #1a/#1c) — run 0 → "paper-canvas-<slug>-run-0".
      assert edit_html =~ ~s(id="paper-canvas-#{@run0_id}")
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
      first_canvas_at = :binary.match(edit_html, ~s(id="paper-canvas-#{@run0_id}")) |> elem(0)
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
      assert html =~ ~s(id="paper-canvas-doc-callout-run-0")
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
      assert html =~ ~s(id="paper-canvas-doc-div-run-0")
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
      assert html =~ ~s(id="paper-canvas-doc-code-run-0")
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
      assert html =~ ~s(id="paper-canvas-doc-diagram-run-0")
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
      assert html =~ ~s(id="paper-canvas-doc-field-run-0")
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

    test "TAIL: [paragraph, field-image, paragraph] renders ONE canvas run containing the picker field (NO per-block boundary widget)" do
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

      # Run-splitter tail: the field-image picker now RIDES the run as a control-atom
      # (its bp-media-picker WC is client-side). So ONE <bp-paper-canvas> run keyed by
      # the run's first block (p-1) — NOT split into two canvases with a per-block widget.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-doc-field-image-run-0")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The field-image is NOT a separate per-block widget — it lives INSIDE the single
      # run (no edit-block wrapper, no per-block BarkparkFieldBlockBridge hook).
      refute html =~ ~s(data-edit-block-id="img-1")
      refute html =~ ~s(phx-hook="BarkparkFieldBlockBridge")

      # The picker rides the run's data-canvas-blocks carrier (its id + label + value are
      # in the Jason-encoded block list on the canvas wrapper).
      assert html =~ "img-1"
      assert html =~ "Hero"

      # The canvas HOST carries the picker fetch-scope (dataset + token) so the mounted
      # bp-media-picker fetches/uploads exactly as the per-block render does.
      assert html =~ ~s(data-canvas-dataset="#{@dataset}")
      assert html =~ ~s(data-canvas-token=)
    end

    test "TAIL: [paragraph, field-reference, paragraph] renders ONE canvas run containing the reference picker" do
      blocks = [
        %{
          "id" => "p-1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "before"}]
        },
        %{
          "id" => "ref-1",
          "type" => "field-reference",
          "label" => "Author",
          "refType" => "author",
          "value" => "doc-7"
        },
        %{
          "id" => "p-2",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after"}]
        }
      ]

      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "doc-field-reference",
          blocks: blocks,
          paper_rev: 0,
          dataset: @dataset,
          api_token_raw: "",
          canvas_eligible: true
        )

      # ONE canvas run — the field-reference picker rides it as a control-atom.
      assert html =~ ~s(<bp-paper-canvas)
      assert html =~ ~s(id="paper-canvas-doc-field-reference-run-0")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # NOT a per-block boundary widget.
      refute html =~ ~s(data-edit-block-id="ref-1")
      refute html =~ ~s(phx-hook="BarkparkFieldBlockBridge")

      # The reference (id + label + refType + value) rides the run's data-canvas-blocks.
      assert html =~ "ref-1"
      assert html =~ "Author"
      assert html =~ "author"
      assert html =~ "doc-7"
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
      assert html =~ ~s(id="paper-canvas-doc-sheet-run-0")
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
    # prose runs keyed by the slug + each run's ORDINAL ("paper-canvas-<slug>-run-<i>";
    # Bug #1a — a STABLE id that survives a leading-block delete, NOT the mutable
    # first-block id; Bug #1c — slug-namespaced so ids never collide across papers).
    # The canvas hook routes each run to its <bp-paper-canvas> and calls
    # applyServerBlocks — an own-echo resets the baseline (no caret move), an external
    # edit re-renders.
    test "S4a: a paper-ops batch pushes bp:canvas-update with the confirmed run blocks (flag ON)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      open_editor(view)

      # The seed [heading, paragraph, callout, paragraph, divider] is ONE maximal
      # run keyed by the slug + its ORDINAL (Bug #1a/#1c) — run 0 → "<slug>-run-0".
      # Edit the intro paragraph.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-intro",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Echoed back."}]}
          }
        ]
      })

      # ONE bp:canvas-update push carrying ONE run (the whole seed is a single run),
      # keyed by the slug + its ORDINAL, carrying the CONFIRMED post-apply blocks —
      # including the edit we just made (the echo the canvas resets its baseline to).
      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: @run0_id, blocks: blocks}] = runs

      # The run blocks are the confirmed blocks IN ORDER, edit applied.
      assert Enum.map(blocks, & &1["id"]) == ["h-1", "p-intro", "c-note", "p-after", "d-end"]

      intro = Enum.find(blocks, &(&1["id"] == "p-intro"))
      assert intro["content"] == [%{"type" => "text", "value" => "Echoed back."}]
    end

    test "Bug #1a: removing the run's LEADING block echoes under the SAME ordinal run_id (no remount, baseline advances)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      open_editor(view)

      # The seed [h-1, p-intro, c-note, p-after, d-end] is ONE run at ordinal 0
      # ("<slug>-run-0"). Remove its LEADING block (h-1) — the case that used to break:
      # under the old first-block-id keying the re-partitioned run_id became "p-intro",
      # so the echo `{run_id: "p-intro"}` no longer matched the still-mounted wrapper
      # "paper-canvas-h-1" → the hook dropped it (baseline stuck) AND the re-render
      # computed a new wrapper id → remount (caret + in-flight edit lost).
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [%{"op" => "remove-block", "id" => "h-1"}]
      })

      assert_push_event(view, "bp:canvas-update", %{runs: runs})

      # Bug #1a fix: the run is STILL ordinal 0 after the leading-block delete, so the
      # echo carries run_id "<slug>-run-0" — the SAME id as the still-mounted wrapper
      # "paper-canvas-<slug>-run-0". So the hook MATCHES it → applyServerBlocks runs →
      # the baseline advances, and the wrapper id is unchanged → no remount.
      assert [%{run_id: @run0_id, blocks: blocks}] = runs

      # The echoed blocks are the SURVIVORS (h-1 gone), in order — the run the
      # still-mounted "paper-canvas-<slug>-run-0" wrapper resets its baseline to.
      assert Enum.map(blocks, & &1["id"]) == ["p-intro", "c-note", "p-after", "d-end"]
    end

    test "S4a: a batch spanning TWO runs (a nested-structure field splits them) pushes ONE entry per run",
         %{conn: conn} do
      # A paper whose composite (nested-structure) field splits two prose runs.
      # partition_runs → [{:run,[p-a]}, {:block, cmp}, {:run,[p-b]}], so the echo
      # carries TWO runs (the boundary block has no canvas to update). (Pickers no
      # longer split — only nested-structure fields do, per the run-splitter tail.)
      split_slug = "2026-06-23-canvas-split"

      blocks = [
        %{
          "id" => "p-a",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "run one"}]
        },
        %{"id" => "cmp-1", "type" => "composite", "fields" => [], "value" => %{}},
        %{
          "id" => "p-b",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "run two"}]
        }
      ]

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: split_slug,
            dataset: @dataset,
            blocks: blocks
          })
        )

      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{split_slug}"))

      open_editor(view)

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-b",
            "patch" => %{"content" => [%{"type" => "text", "value" => "run two edited"}]}
          }
        ]
      })

      assert_push_event(view, "bp:canvas-update", %{runs: runs})

      # TWO runs (the composite boundary is NOT echoed — it has no canvas),
      # keyed by the slug + each run's ORDINAL (Bug #1a/#1c): the first prose run
      # is "<slug>-run-0", the second (after the nested-structure boundary) is
      # "<slug>-run-1".
      run0 = "#{split_slug}-run-0"
      run1 = "#{split_slug}-run-1"
      assert [%{run_id: ^run0, blocks: run_a}, %{run_id: ^run1, blocks: run_b}] = runs
      assert Enum.map(run_a, & &1["id"]) == ["p-a"]
      assert Enum.map(run_b, & &1["id"]) == ["p-b"]

      # The echoed p-b run carries the confirmed edit.
      assert hd(run_b)["content"] == [%{"type" => "text", "value" => "run two edited"}]
    end

    test "t12a: a fleet-containing doc [heading, task-board, paragraph] echoes ONE run (the fleet block no longer splits)",
         %{conn: conn} do
      # push_canvas_echo partitions with the SAME PaperCanvas.partition_runs the
      # editor mounts, so after the t12a flip a top-level fleet block folds INTO the
      # run — the whole doc echoes as ONE run keyed "<slug>-run-0", the fleet block riding
      # verbatim between the prose blocks (it paints in-canvas via bpFleet, D8/D5).
      fleet_slug = "2026-07-06-canvas-fleet"

      blocks = [
        %{"id" => "f-h", "type" => "heading", "text" => "Board", "level" => 2},
        %{"id" => "f-board", "type" => "task-board", "snapshot" => []},
        %{
          "id" => "f-after",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "after the board"}]
        }
      ]

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: fleet_slug,
            dataset: @dataset,
            blocks: blocks
          })
        )

      {:ok, view, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{fleet_slug}"))

      open_editor(view)

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "f-after",
            "patch" => %{"content" => [%{"type" => "text", "value" => "edited"}]}
          }
        ]
      })

      assert_push_event(view, "bp:canvas-update", %{runs: runs})

      # ONE run — the task-board rides it verbatim, no boundary split.
      fleet_run0 = "#{fleet_slug}-run-0"
      assert [%{run_id: ^fleet_run0, blocks: run_blocks}] = runs
      assert Enum.map(run_blocks, & &1["id"]) == ["f-h", "f-board", "f-after"]

      # The fleet block rode VERBATIM (D5): still a raw task-board, no snapshot
      # resolution serialized into the echoed baseline.
      board = Enum.find(run_blocks, &(&1["id"] == "f-board"))
      assert board["type"] == "task-board"
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
      assert html =~ ~s(id="paper-canvas-doc-embed-run-0")
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, html)) == 1

      # The embed is NOT a separate per-block widget — it lives INSIDE the single run.
      refute html =~ ~s(data-edit-block-id="em-1")
      refute html =~ ~s(data-block-type="embed")

      # The embed rides the run's data-canvas-blocks carrier VERBATIM (its id + target
      # are in the Jason-encoded block list on the canvas wrapper).
      assert html =~ "em-1"
      assert html =~ "Linked Note"
    end

    test "Bug #1c: patch-navigating to ANOTHER paper changes every canvas wrapper id (no stale ignore-wrapper reuse)",
         %{conn: conn} do
      other_slug = "2026-07-10-canvas-other"

      other_blocks = [
        %{
          "id" => "o-p1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "The other paper's body."}]
        }
      ]

      {:ok, _} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: other_slug,
            dataset: @dataset,
            blocks: other_blocks
          })
        )

      {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      assert html =~ ~s(id="paper-canvas-#{@run0_id}")

      # Patch-navigate WITHIN the mounted LiveView to the other paper — the exact
      # gesture of clicking another paper in the Studio list. The rendered wrapper
      # id must be the OTHER paper's (slug-namespaced) and the first paper's id
      # must be GONE. A bare-ordinal id ("paper-canvas-run-0") is identical for
      # both papers, and morphdom's global keyed-node reuse then TRANSPLANTS the
      # old paper's phx-update="ignore" wrapper — old canvas content and all —
      # into the new editor: the stuck-paper navigation bug. Distinct ids force
      # remove+add → a fresh hook mount → the new paper's blocks seed the canvas.
      html = render_patch(view, scoped_studio("/d/#{@dataset}/studio/paper/#{other_slug}"))

      assert html =~ ~s(id="paper-canvas-#{other_slug}-run-0")
      refute html =~ ~s(id="paper-canvas-#{@run0_id}")
    end
  end

  # ── 2b. FLAG-ON — full server-side E2E loop ─────────────────────────────────
  #
  # The continuous-canvas edit→persist→echo→reload loop, driven through the REAL
  # LiveView handler (not a unit of the partitioner). Each case pushes the same
  # `paper-ops` event the JS canvas hook forwards (`render_hook(view, "paper-ops",
  # %{"ops" => [...]})`), then asserts the WHOLE loop:
  #
  #   1. PERSIST — re-read the paper's stored blocks (Content.paper_blocks/2, the
  #      same read sync_paper_edit_doc uses) and assert the mutation landed on disk.
  #   2. ECHO    — assert_push_event "bp:canvas-update" carries the CONFIRMED run(s)
  #      keyed by slug+ordinal run_id, with the edit applied.
  #   3. RELOAD  — (case 7) re-mount live/2 for the same paper and assert the canvas
  #      run renders the EDITED blocks — the strongest "it really persisted" proof.
  #
  # This is the server-side proxy for the real-Studio cutover E2E: the canvas has
  # only been harness-verified client-side; this closes the live-integration gap
  # WITHOUT a browser by exercising paper_ops/2 → apply_paper_block_ops →
  # sync_paper_edit_doc → push_canvas_echo end-to-end.
  describe "flag ON — full server-side E2E loop" do
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

    # The seed paper is ONE maximal run (heading+paragraph+callout+paragraph+divider
    # are all canvas-eligible), so its echo is a single entry keyed "<slug>-run-0".
    @seed_order ["h-1", "p-intro", "c-note", "p-after", "d-end"]

    # Mount the Studio paper editor flag-ON for the seed paper and open the editor.
    defp mount_canvas_editor(conn, slug \\ @slug) do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
      open_editor(view)
      view
    end

    # Re-read the persisted block ids in stored order — the on-disk truth.
    defp persisted_ids(slug \\ @slug) do
      Content.paper_blocks(slug, @dataset) |> Enum.map(& &1["id"])
    end

    defp persisted_block(id, slug \\ @slug) do
      Content.paper_blocks(slug, @dataset) |> Enum.find(&(&1["id"] == id))
    end

    # ── 1. PATCH round-trip ───────────────────────────────────────────────────
    test "PATCH: patch-block persists the new content, echoes the confirmed run, ordinal keying holds",
         %{conn: conn} do
      view = mount_canvas_editor(conn)

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-intro",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Patched intro."}]}
          }
        ]
      })

      # (a) the PERSISTED paper reflects the new content (re-read from disk).
      assert persisted_block("p-intro")["content"] ==
               [%{"type" => "text", "value" => "Patched intro."}]

      # The other blocks are untouched and order is preserved.
      assert persisted_ids() == @seed_order
      assert persisted_block("h-1")["text"] == "Canvas Paper"

      # (b) the echo carries the CONFIRMED run with the edit; (c) keyed by ordinal.
      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: @run0_id, blocks: blocks}] = runs
      assert Enum.map(blocks, & &1["id"]) == @seed_order

      intro = Enum.find(blocks, &(&1["id"] == "p-intro"))
      assert intro["content"] == [%{"type" => "text", "value" => "Patched intro."}]
    end

    # ── 2. INSERT mid-run ─────────────────────────────────────────────────────
    test "INSERT: insert-after a client-minted block lands at the right position, survivors intact, echo carries it",
         %{conn: conn} do
      view = mount_canvas_editor(conn)

      new_block = %{
        "id" => "p-fresh",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Freshly inserted."}]
      }

      # insert-after uses "afterId" (NOT "after" — that key is move-block's). Insert
      # directly after p-intro → it lands at index 2, between p-intro and c-note.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [%{"op" => "insert-after", "afterId" => "p-intro", "block" => new_block}]
      })

      # Persisted at the right position with its client-minted id; survivors intact.
      assert persisted_ids() == ["h-1", "p-intro", "p-fresh", "c-note", "p-after", "d-end"]

      assert persisted_block("p-fresh")["content"] ==
               [%{"type" => "text", "value" => "Freshly inserted."}]

      # Echo: still ONE run (the inserted paragraph is canvas-eligible), and the new
      # block rides it in position.
      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: @run0_id, blocks: blocks}] = runs

      assert Enum.map(blocks, & &1["id"]) ==
               ["h-1", "p-intro", "p-fresh", "c-note", "p-after", "d-end"]
    end

    # ── 3. REMOVE ─────────────────────────────────────────────────────────────
    test "REMOVE: remove-block deletes it from disk, survivors keep ids/order, echo reflects it",
         %{conn: conn} do
      view = mount_canvas_editor(conn)

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [%{"op" => "remove-block", "id" => "c-note"}]
      })

      # Gone from disk; the survivors keep their ids AND their relative order.
      assert persisted_ids() == ["h-1", "p-intro", "p-after", "d-end"]
      assert persisted_block("c-note") == nil

      # Echo: still ONE run, now without c-note.
      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: @run0_id, blocks: blocks}] = runs
      assert Enum.map(blocks, & &1["id"]) == ["h-1", "p-intro", "p-after", "d-end"]
    end

    # ── 4. MOVE ───────────────────────────────────────────────────────────────
    test "MOVE: move-block re-orders the persisted blocks, echo reflects the new order",
         %{conn: conn} do
      view = mount_canvas_editor(conn)

      # move-block uses "after" (the anchor id). Move p-after to just after h-1 — it
      # jumps from index 3 to index 1.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [%{"op" => "move-block", "id" => "p-after", "after" => "h-1"}]
      })

      assert persisted_ids() == ["h-1", "p-after", "p-intro", "c-note", "d-end"]

      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: @run0_id, blocks: blocks}] = runs
      assert Enum.map(blocks, & &1["id"]) == ["h-1", "p-after", "p-intro", "c-note", "d-end"]
    end

    # ── 5. BATCH — patch + insert + remove in one ordered atomic fold ──────────
    test "BATCH: one paper-ops with patch+insert+remove composes exactly, a SINGLE echo fires",
         %{conn: conn} do
      view = mount_canvas_editor(conn)

      inserted = %{
        "id" => "p-batch",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Batch inserted."}]
      }

      # An ordered batch: patch h-1's text, insert a paragraph after p-intro, remove
      # the divider. The fold applies them in order; the persisted result is the
      # COMPOSED effect of all three.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{"op" => "patch-block", "id" => "h-1", "patch" => %{"text" => "Batched Heading"}},
          %{"op" => "insert-after", "afterId" => "p-intro", "block" => inserted},
          %{"op" => "remove-block", "id" => "d-end"}
        ]
      })

      # Composed end-state: heading text patched, p-batch inserted at index 2, d-end gone.
      assert persisted_ids() == ["h-1", "p-intro", "p-batch", "c-note", "p-after"]
      assert persisted_block("h-1")["text"] == "Batched Heading"

      assert persisted_block("p-batch")["content"] ==
               [%{"type" => "text", "value" => "Batch inserted."}]

      # Cross-check against the pure batch primitive over the seed: same end-state.
      {:ok, expected} =
        Barkpark.PortableDoc.Patch.apply_patches(seed_blocks(), [
          %{"op" => "patch-block", "id" => "h-1", "patch" => %{"text" => "Batched Heading"}},
          %{"op" => "insert-after", "afterId" => "p-intro", "block" => inserted},
          %{"op" => "remove-block", "id" => "d-end"}
        ])

      assert Content.paper_blocks(@slug, @dataset) == expected

      # Exactly ONE echo for the whole batch (NOT one per op).
      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: @run0_id, blocks: blocks}] = runs
      assert Enum.map(blocks, & &1["id"]) == ["h-1", "p-intro", "p-batch", "c-note", "p-after"]

      # No SECOND echo leaked from the same batch.
      refute_push_event(view, "bp:canvas-update", %{}, 50)
    end

    # ── 6. INCREMENTAL after echo — the loop is repeatable ────────────────────
    test "INCREMENTAL: a SECOND edit after a batch+echo persists (the baseline advanced)",
         %{conn: conn} do
      view = mount_canvas_editor(conn)

      # First batch + its echo.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-intro",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Round one."}]}
          }
        ]
      })

      assert_push_event(view, "bp:canvas-update", %{runs: [%{run_id: @run0_id}]})

      assert persisted_block("p-intro")["content"] == [
               %{"type" => "text", "value" => "Round one."}
             ]

      # SECOND, independent edit on the same still-mounted view — drives the loop again.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-after",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Round two."}]}
          }
        ]
      })

      # Both edits persisted — the loop advanced, it is not stuck on the first batch.
      assert persisted_block("p-intro")["content"] == [
               %{"type" => "text", "value" => "Round one."}
             ]

      assert persisted_block("p-after")["content"] == [
               %{"type" => "text", "value" => "Round two."}
             ]

      # The second edit produced its OWN echo carrying BOTH confirmed edits.
      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: @run0_id, blocks: blocks}] = runs

      assert Enum.find(blocks, &(&1["id"] == "p-after"))["content"] ==
               [%{"type" => "text", "value" => "Round two."}]
    end

    # ── 7. RELOAD round-trip — the strongest "it really persisted" check ──────
    test "RELOAD: after edits, a fresh live/2 mount renders the EDITED blocks in the canvas",
         %{conn: conn} do
      view = mount_canvas_editor(conn)

      # A unique sentinel so we can assert it shows up in the re-mounted canvas HTML.
      sentinel = "Survives-a-reload-#{System.unique_integer([:positive])}"

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-intro",
            "patch" => %{"content" => [%{"type" => "text", "value" => sentinel}]}
          }
        ]
      })

      assert_push_event(view, "bp:canvas-update", %{runs: _})
      assert persisted_block("p-intro")["content"] == [%{"type" => "text", "value" => sentinel}]

      # RE-MOUNT a FRESH LiveView for the same paper (flag still ON via this
      # describe's setup) and open the editor — the canvas run must carry the
      # EDITED block. The sentinel rides the run's data-canvas-blocks carrier
      # (Jason-encoded), so it appears in the re-mounted editor HTML.
      {:ok, reloaded, _html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

      reload_html = open_editor(reloaded)

      assert reload_html =~ ~s(id="paper-canvas-#{@run0_id}")
      assert reload_html =~ "data-canvas-blocks"
      # The edit survived persistence into a brand-new mount's canvas.
      assert reload_html =~ sentinel
    end

    # ── 8. Idempotent-remove safety (audit Bug #1b) at the LiveView level ──────
    test "BATCH with a stale remove of an ALREADY-absent id + a real patch — the patch STILL applies (no Edit failed)",
         %{conn: conn} do
      view = mount_canvas_editor(conn)

      # A batch the canvas can legitimately send when an echo crosses a re-send in
      # flight: it removes "ghost-id" (never existed / already gone) AND patches a
      # real block. Without the idempotent-remove fix in patch.ex, the remove of an
      # absent id would HALT the atomic fold with {:block_not_found}, the whole batch
      # would error → "Edit failed" flash → the real patch would be LOST.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{"op" => "remove-block", "id" => "ghost-id"},
          %{
            "op" => "patch-block",
            "id" => "p-after",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Patched past a ghost."}]}
          }
        ]
      })

      # The real patch landed despite the no-op remove riding the same batch.
      assert persisted_block("p-after")["content"] ==
               [%{"type" => "text", "value" => "Patched past a ghost."}]

      # The seed order is intact (nothing was actually removed; ghost-id never existed).
      assert persisted_ids() == @seed_order

      # The handler did NOT flash "Edit failed" — the batch succeeded end-to-end, so
      # an echo fired carrying the confirmed patch.
      refute render(view) =~ "Edit failed"

      assert_push_event(view, "bp:canvas-update", %{runs: runs})
      assert [%{run_id: @run0_id, blocks: blocks}] = runs

      assert Enum.find(blocks, &(&1["id"] == "p-after"))["content"] ==
               [%{"type" => "text", "value" => "Patched past a ghost."}]
    end
  end

  # The seed blocks, verbatim — shared by the batch cross-check (it folds the pure
  # primitive over these and asserts the persisted result equals it).
  defp seed_blocks do
    [
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
  end

  # ── 3. paper-ops HANDLER (flag OFF — the echo guard) ────────────────────────
  #
  # The `refute_push_event` guard proves the OFF path leaks NO `bp:canvas-update`
  # echo. With the canvas now the mainline default (D7/D9), OFF is an explicit
  # opt-out — pin it so these keep exercising the flag-OFF echo behavior.
  describe "paper-ops HANDLER (flag OFF — BARKPARK_PAPER_CANVAS=0)" do
    setup do
      prev = System.get_env("BARKPARK_PAPER_CANVAS")
      System.put_env("BARKPARK_PAPER_CANVAS", "0")

      on_exit(fn ->
        case prev do
          nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
          v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
        end
      end)

      :ok
    end

    test "paper-ops folds a batch through apply_patches + persists identically to per-block",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      open_editor(view)

      pid_before = view.pid

      # A <bp-paper-canvas> run emits bp-canvas-ops {ops:[…]}; the hook forwards it
      # as `paper-ops`. Here: one patch-block editing the intro paragraph's text —
      # the SAME op shape the per-block path persists, just inside a batch array.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-intro",
            "patch" => %{
              "content" => [%{"type" => "text", "value" => "Edited via canvas batch."}]
            }
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

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => ops
      })

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

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => []
      })

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => "not-a-list"
      })

      render_hook(view, "paper-ops", %{})

      assert Content.paper_blocks(@slug, @dataset) == before
      assert view.pid == pid_before
      assert Process.alive?(view.pid)
    end
  end

  # ── 4. A LANDED SAVE SAYS SO (spd-w18-save-announces) ───────────────────────
  #
  # MEASURED ON THE DEPLOYED BUILD: after a canvas save the API proved persisted
  # (blocks:3, _updatedAt 4s after _createdAt), [data-test-id="bp-paper-footer-save"]
  # — a role="status" aria-live="polite" span and the page's ONLY aria-live region
  # — was THE EMPTY STRING, polled for 25 seconds. The footer counts DID move, so
  # the page was alive; the announcement was silent.
  #
  # CAUSE: `paper_ops/2`'s `{:ok, _result}` branch assigned no save_status at all,
  # while all three of its error branches assign "Save failed" and
  # `save_status_label(nil)` renders "". So the affordance could only ever say
  # nothing or failure. These tests pin BOTH arms so the asymmetry cannot return,
  # and pin that the fix did NOT flatten success into failure.
  #
  # Flag pinned ON (the deployed default, config/runtime.exs forces "1" in :prod)
  # with the prev/put/on_exit idiom — four sibling suites set it to "0"
  # process-globally, so inheriting it would be an order-dependent green (D233).
  describe "a landed save announces itself (flag ON — BARKPARK_PAPER_CANVAS=1)" do
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

    # The socket-owned truth. The canvas run wrapper is phx-update="ignore", so
    # the assign is asserted directly (never DOM inside the canvas); the footer is
    # server-rendered chrome OUTSIDE the ignore wrapper, so it IS assertable.
    defp save_status_assign(view), do: :sys.get_state(view.pid).socket.assigns[:save_status]

    defp footer_save_text(view) do
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test-id="bp-paper-footer-save"]))
      |> LazyHTML.text()
      |> String.trim()
    end

    test "a SUCCESSFUL paper-ops batch assigns save_status and renders it in the aria-live region",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      open_editor(view)

      # Baseline: nothing written yet, so the region is honestly silent.
      assert save_status_assign(view) == ""
      assert footer_save_text(view) == ""

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-intro",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Announced intro."}]}
          }
        ]
      })

      # The write really landed (so the announcement is not announcing nothing).
      assert Content.paper_blocks(@slug, @dataset)
             |> Enum.find(&(&1["id"] == "p-intro"))
             |> Map.get("content") == [%{"type" => "text", "value" => "Announced intro."}]

      # (a) the socket assign — the SAME token the single-op path
      #     (paper_pane_op/2) assigns; one vocabulary across both write seams.
      assert save_status_assign(view) == "Auto-saved"

      # (b) the rendered aria-live region actually SAYS it (✓ affix from
      #     PaperEditor.save_status_label/1).
      assert footer_save_text(view) == "✓ Auto-saved"
    end

    test "a REFUSED paper-ops batch still announces Save failed (the fix did not flatten the distinction)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      open_editor(view)

      before = Content.paper_blocks(@slug, @dataset)

      # Removing every substantive block hollows the paper — the server-owned
      # hollow ratchet HALTS the batch (put_paper_halt/2).
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{"op" => "remove-block", "id" => "p-intro"},
          %{"op" => "remove-block", "id" => "c-note"},
          %{"op" => "remove-block", "id" => "p-after"}
        ]
      })

      # The write was refused — the paper is untouched.
      assert Content.paper_blocks(@slug, @dataset) == before

      assert save_status_assign(view) == "Save failed"
      assert footer_save_text(view) == "Save failed"
    end

    test "success and failure are DISTINGUISHABLE on the same mounted view", %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      open_editor(view)

      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-intro",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Round one."}]}
          }
        ]
      })

      assert footer_save_text(view) == "✓ Auto-saved"

      # A refused batch REPLACES the calm token — a rejected write must never
      # leave a stale "Auto-saved" on screen.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{"op" => "remove-block", "id" => "p-intro"},
          %{"op" => "remove-block", "id" => "c-note"},
          %{"op" => "remove-block", "id" => "p-after"}
        ]
      })

      assert footer_save_text(view) == "Save failed"

      # …and a subsequent good write recovers the announcement.
      render_hook(view, "paper-ops", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "ops" => [
          %{
            "op" => "patch-block",
            "id" => "p-after",
            "patch" => %{"content" => [%{"type" => "text", "value" => "Round three."}]}
          }
        ]
      })

      assert footer_save_text(view) == "✓ Auto-saved"
    end
  end
end
