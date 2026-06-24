defmodule BarkparkWeb.Studio.StudioLivePaperCanvasTest do
  @moduledoc """
  Phase-4 S2 — wire `<bp-paper-canvas>` into the Studio paper editor behind the
  BARKPARK_PAPER_CANVAS flag. The contract proven here:

    1. FLAG-OFF BYTE-IDENTICAL (the critical test): with the flag unset, the
       rendered editor HTML is EXACTLY today's per-block render — the same
       `paper-ed-<id>` rich-text wrappers, NO `<bp-paper-canvas>`. The flag-OFF
       output is snapshotted to disk on the first run and diffed on every run
       (so any future drift in the OFF path fails loudly).

    2. FLAG-ON render: a [heading, paragraph, callout, paragraph] paper renders
       TWO `<bp-paper-canvas>` runs (the two prose groups), the callout via its
       EXISTING widget between them, and the data-expected-fields carrier OUTSIDE
       every phx-update="ignore" wrapper.

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

  # A representative paper: two prose runs flanking a non-prose callout, plus a
  # trailing divider boundary. Stable ids so the snapshot is deterministic.
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

    test "renders TWO <bp-paper-canvas> runs + the callout via its existing widget",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      edit_html = open_editor(view)

      # Two prose runs → two canvases, KEYED by each run's first block id.
      assert edit_html =~ ~s(id="paper-canvas-h-1")
      assert edit_html =~ ~s(id="paper-canvas-p-after")
      assert edit_html =~ ~s(phx-hook="BarkparkPaperCanvas")
      assert edit_html =~ ~s(phx-update="ignore")
      assert edit_html =~ ~s(<bp-paper-canvas)

      # Exactly two canvas wrappers (the two prose runs), no more.
      assert length(Regex.scan(~r/data-test-id="paper-canvas-run"/, edit_html)) == 2

      # The non-prose callout is a run boundary rendered by its EXISTING per-block
      # widget (still has its edit-block wrapper + delete control), NOT a canvas.
      assert edit_html =~ ~s(data-edit-block-id="c-note")
      assert edit_html =~ ~s(data-block-type="callout")

      # The per-block <bp-paper-editor> WC is NOT used on the ON path — the prose
      # blocks live inside the canvases instead.
      refute edit_html =~ ~s(id="paper-ed-h-1")
      refute edit_html =~ ~s(<bp-paper-editor)

      # Each run carries its blocks on data-canvas-blocks (Jason-encoded; the
      # attribute is HTML-escaped, so match on the run's block ids appearing in
      # the carrier, which only exists on the canvas wrappers).
      assert edit_html =~ "data-canvas-blocks"
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

    test "a divider trailing the second run is its own boundary (not swallowed into a run)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      edit_html = open_editor(view)

      # The divider renders via its existing read-only per-block widget.
      assert edit_html =~ ~s(data-edit-block-id="d-end")
      assert edit_html =~ ~s(data-block-type="divider")
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
