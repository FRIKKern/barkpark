defmodule Barkpark.PortableDoc.Render.CanvasReaderParityGateTest do
  @moduledoc """
  Canvas ⇄ reader render-parity GATE — pd-doctrine rule 3 ("100% render parity:
  every element in the canvas looks exactly as the frontend render; same
  producer, byte for byte"), charter t10, decisions D6 + D8.

  ## What this gate locks

  The Beta canvas is THE paper editor. For every non-prose FLEET block (tasks,
  task-board, roadmap, cards, pipeline, notes, status-legend, task-detail, form,
  asciicast, diagram, plus the 5 data-viz kinds stat/stats/stat-grid/heatmap/chart
  — and the sheet/embed chip-carry pair) the canvas must show
  the reader's own render. D8 mandates ONE producer: display HTML is produced by
  `Render.render_block/2` (the `/papers` reader's emitter) server-side and painted
  into read-only canvas atoms; the block itself rides verbatim (bpBlock) and stays
  the save baseline. The canvas node-view JS NEVER hand-mirrors fleet markup.

  "100% parity" is only a CLAIM until CI enforces it — hand-kept parity rots (the
  w3 View↔Edit tripwire, `view_edit_parity_test.exs`, was built for exactly this
  reason). This file is the machine gate that makes canvas⇄reader drift impossible
  to ship. It rides the standard blocking `mix-test` job in
  `.github/workflows/elixir.yml` (default `mix test` discovers it) — NOT a new
  advisory check.

  ## Two sanctioned parity mechanisms (and no third)

    * ONE READER PRODUCER (the component fleet, form, and the diagram/asciicast
      figures) — every one of these types has EXACTLY ONE reader emitter
      (`Components.*`/`Figures.*`/`Forms.*`), and `Render.render_block(block,
      %{style: :article})` — the call t8's server paint makes — routes through it
      byte for byte (§1), emitting the emitter's HTML verbatim as a `_raw` escape
      hatch with no context-dependent walk (§2). The component fleet is painted
      into the canvas from that server HTML; diagram/asciicast edit their source
      in a canvas island (bp-canvas-diagram) and let the reader render the figure.
      Either way the canvas holds NO competing HTML producer (§3), so the paint /
      the saved-block re-render matches the reader by construction.

    * VERBATIM-CARRY (sheet, embed) — the canvas shows a read-only CHIP, not the
      reader render, but carries the WHOLE block on `bpBlock` with ZERO
      value/content ops (embed-node.js). So the SAVED block reader-renders
      byte-identically to the original: parity of the persisted bytes. §4 proves
      the reader render is deterministic and the canvas JS shows only chip
      markup, never the reader's sheet/embed markup.

  §3 is the shared teeth for BOTH: the ENTIRE editor bundle JS
  (`assets/paper-editor/src/**/*.js` — node views, convert, slash menu, all of
  it) contains NONE of the reader fleet markup class literals — a fleet block
  can appear in the canvas ONLY via the server producer or the verbatim chip,
  never a second hand-written JS producer, in any source file. A future wave
  (t8 generalizes the server paint; a later slice touches the node views) that
  hand-mirrors `bp-tasks` markup into the JS reds §3; one that forks the server
  emitter reds §1.

  ## Injected-drift proof (mutation-verified — re-verify after any change)

  §5 models the exact D8 violations (a hand-mirrored class rename; a wrapper-div
  second producer) and proves the byte-compare catches them. To re-verify the
  gate has real teeth against the LIVE code (all three mutation-verified
  2026-07-06):

    1. Compose fork — wrap the `"cards"` clause in `render/compose.ex` so the
       `_raw` html becomes `"<div…>" <> Components.cards_html(b) <> "</div>"`.
       render_block now diverges from the one emitter: §1 `cards` RED and §2
       `cards` RED. Revert.
    2. JS hand-mirror — add the string `"bp-tasks"` to ANY editor source file
       (e.g. `assets/paper-editor/src/canvas/run-convert.js` or `src/index.js`):
       §3 RED (and §5's clean-JS precondition RED). Revert.

  NOTE — editing a SHARED emitter (e.g. appending a byte in
  `Components.tasks_html/1`) does NOT red §1: render_block calls that same
  emitter, so both sides of the compare move together. That is CORRECT — a
  reader-render change the canvas inherits verbatim keeps parity. §1 reds only on
  a FORK between render_block's path and the emitter (mutation 1), which is the
  drift this gate exists to catch.

  Author-pinned literal fixtures (no `query`, no snapshot resolution, no Repo) so
  the gate runs with the Tasks plugin OFF and no live DB — CI-safe and offline.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.{Components, Compose, DataViz, Figures, Forms}

  @article %{style: :article}

  # ── The FLEET corpus ────────────────────────────────────────────────────────
  #
  # SERVER-PAINT fleet: {label, block, one_reader_emitter_fn, reader_markup_sig}.
  # `emitter_fn` is the SINGLE reader-side HTML producer for that type;
  # `render_block(:article)` must equal it byte for byte (§1). `markup_sig` is a
  # class literal the reader emits that the canvas JS must NOT hand-mirror (§3).
  # Every type t8 enumerates is present — a new fleet type without a row here is
  # an ungated paint path.
  defp painted_fleet do
    [
      {"tasks",
       %{
         "type" => "tasks",
         "title" => "Plan",
         "snapshot" => [
           %{"title" => "Do the thing", "status" => "ready", "priority" => 1},
           %{"title" => "Finished", "status" => "done"}
         ]
       }, &Components.tasks_html/1, "bp-tasks"},
      {"task-list (alias)",
       %{"type" => "task-list", "snapshot" => [%{"title" => "Aliased", "status" => "open"}]},
       &Components.tasks_html/1, "bp-tasks"},
      {"task-detail",
       %{
         "type" => "task-detail",
         "task" => %{"title" => "A task", "status" => "ready", "priority" => 2, "worker" => "me"}
       }, &Components.task_detail_html/1, "bp-tdetail"},
      {"task-board",
       %{
         "type" => "task-board",
         "snapshot" => [
           %{"title" => "Ready one", "status" => "ready"},
           %{"title" => "Done one", "status" => "done"}
         ]
       }, &Components.task_board_html/1, "bp-board"},
      {"roadmap",
       %{
         "type" => "roadmap",
         "snapshot" => [%{"title" => "Phase 1", "status" => "ready", "left" => 0, "width" => 40}],
         "today" => 20,
         "scale" => ["Q1", "Q2"]
       }, &Components.roadmap_html/1, "bp-roadmap"},
      {"cards",
       %{
         "type" => "cards",
         "items" => [%{"title" => "Card", "text" => "body", "tone" => "info"}]
       }, &Components.cards_html/1, "bp-cards"},
      {"pipeline",
       %{
         "type" => "pipeline",
         "nodes" => [
           %{"kind" => "source", "title" => "emit", "source" => true},
           %{"kind" => "gate", "title" => "check"}
         ]
       }, &Components.pipeline_html/1, "bp-pipe"},
      {"notes",
       %{
         "type" => "notes",
         "items" => [%{"label" => "why", "lead" => "Lead", "text" => "matters"}]
       }, &Components.notes_html/1, "bp-notes"},
      {"status-legend", %{"type" => "status-legend"}, &Components.status_legend_html/1,
       "bp-legend"},
      {"form",
       %{
         "type" => "form",
         "questions" => [%{"id" => "q1", "prompt" => "Ready?", "type" => "text"}]
       }, &Forms.form_html(&1, :article), "bp-form"},
      {"asciicast",
       %{"type" => "asciicast", "src" => "https://example.com/c.cast", "caption" => "A cast"},
       &Figures.asciicast_html(&1["src"], &1["caption"], Map.get(&1, "poster", ""), :article),
       "bp-asciicast"},
      {"diagram", %{"type" => "diagram", "source" => "graph TD; A-->B", "caption" => "A graph"},
       &Figures.diagram_html(&1["source"], &1["caption"], :article), "class=\"mermaid\""},
      # pd-ee-dataviz-editors (charter D3): the 5 DATA-VIZ kinds are server-painted
      # bpFleet atoms (a parallel painted-set — run-convert.js CANVAS_DATAVIZ_TYPES /
      # paper_canvas.ex @canvas_dataviz_types / shared/paper.ex @dataviz_render_types),
      # painted by the ONE Render.DataViz emitter per kind. Fixtures carry real data
      # shaped per data_viz.ex so every emitter branch is genuinely exercised
      # (an empty fixture would vacuously test the `bp-dataviz--empty` box).
      # `stat-grid` is the accepted alias of `stats` (compose.ex normalizes both onto
      # stats_html — the task-list ⇄ tasks precedent).
      {"stat",
       %{
         "type" => "stat",
         "value" => "71",
         "label" => "tests green",
         "max" => 118,
         "denom" => "118",
         "spark" => [1, 3, 2, 5]
       }, &DataViz.stat_html/1, "bp-stat"},
      {"stats",
       %{
         "type" => "stats",
         "items" => [
           %{"value" => "9", "label" => "open"},
           %{"value" => "4", "label" => "done"}
         ]
       }, &DataViz.stats_html/1, "bp-stats"},
      {"stat-grid (alias)",
       %{
         "type" => "stat-grid",
         "items" => [%{"value" => "12", "label" => "aliased"}]
       }, &DataViz.stats_html/1, "bp-stats"},
      {"heatmap",
       %{
         "type" => "heatmap",
         "cells" => [[1, 2, 3], [4, 5, 6]],
         "rowLabels" => ["mon", "tue"],
         "colLabels" => ["a", "b", "c"]
       }, &DataViz.heatmap_html/1, "bp-heat"},
      {"chart",
       %{
         "type" => "chart",
         "series" => [%{"label" => "velocity", "points" => [1, 4, 2, 8]}],
         "axes" => %{"min" => 0, "xLabels" => ["w1", "w4"]},
         "caption" => "A chart"
       }, &DataViz.chart_html/1, "bp-chart"}
    ]
  end

  # VERBATIM-CARRY fleet: {label, block, reader_markup_sig}. The canvas shows a
  # chip; the block rides verbatim, so reader(saved) == reader(original). The
  # reader markup below must never appear in the canvas JS (§3/§4).
  defp chip_carry do
    [
      {"sheet",
       %{
         "type" => "sheet",
         "ref" => "budget",
         "snapshot" => %{"rows" => [["a", "b"], ["1", "2"]]}
       }, "bp-sheet__td"},
      {"embed", %{"type" => "embed", "target" => "Other Note"}, "paper-embed"}
    ]
  end

  # ── §1 BYTE-PARITY — the canvas paint producer == the ONE reader emitter ─────
  #
  # D8: the canvas paints `Render.render_block(block, %{style: :article})`. This
  # asserts that call routes each fleet type through EXACTLY its one named reader
  # emitter, byte for byte — the reader path carries no second/wrapped producer.
  # Any fork (a copied emitter, a compose wrapper, an :article-only branch) reds.

  test "§1 render_block(:article) is byte-identical to each type's one reader emitter" do
    mismatches =
      for {label, block, emitter, _sig} <- painted_fleet(),
          reader = Render.render_block(block, @article),
          direct = emitter.(block),
          reader != direct do
        "#{label}: render_block=#{byte_size(reader)}B emitter=#{byte_size(direct)}B differ"
      end

    assert mismatches == [],
           """
           Canvas⇄reader parity broken — render_block(:article) no longer equals
           the type's single reader emitter, so the canvas paint (which calls
           render_block) has forked from the reader. Close toward VIEW (D6): make
           the reader path route through the one emitter again. Divergences:

           #{Enum.join(mismatches, "\n")}
           """
  end

  test "§1 every painted-fleet render is non-empty and carries its signature markup (no vacuous pass)" do
    # Guards §1 against an emitter that silently returns "" (== "" would pass the
    # diff vacuously): a real paint must be non-empty AND carry its class marker.
    for {label, block, _emitter, sig} <- painted_fleet() do
      html = Render.render_block(block, @article)
      assert byte_size(html) > 0, "#{label}: render_block(:article) produced empty HTML"

      assert String.contains?(html, sig),
             "#{label}: render_block(:article) is missing its signature markup #{inspect(sig)} — the fixture no longer exercises the emitter"
    end
  end

  test "§1 questionnaire is a PURE alias of form — same one producer, byte for byte" do
    # Like task-list ⇄ tasks (covered in the corpus), `questionnaire` is an
    # alias of `form` (compose.ex normalizes type + kind before the one Forms
    # emitter). Assert the OBSERVABLE alias property — the alias renders
    # byte-identically to the normalized form block — so giving questionnaire
    # its own producer (an alias fork) reds without this test mirroring
    # compose's internal normalization steps.
    questions = [%{"id" => "q1", "prompt" => "Ready?", "type" => "text"}]
    alias_block = %{"type" => "questionnaire", "questions" => questions}
    normalized = %{"type" => "form", "kind" => "questionnaire", "questions" => questions}

    alias_html = Render.render_block(alias_block, @article)

    assert alias_html == Render.render_block(normalized, @article),
           "questionnaire no longer routes through form's one producer — an alias fork has crept in"

    assert String.contains?(alias_html, "bp-form-questionnaire"),
           "questionnaire lost its kind discriminator class — the alias fixture no longer exercises the form emitter"
  end

  test "§1 a legacy snapshot-only task-list renders byte-identically to its tasks emitter (backward-compat freeze)" do
    # The live-data task-list WIDGET is ADDITIVE: it never touches the reader clause
    # (compose.ex:688 + Components.tasks_html). A LEGACY author-pinned task-list (a
    # literal `snapshot`, NO `query`) must render EXACTLY as before. Freeze that: the
    # legacy block routes through the ONE tasks emitter byte for byte, AND is
    # byte-identical to the equivalent `tasks` block (a live task-list resolves
    # query→snapshot BEFORE this clause, so the snapshot form is a pure alias).
    legacy = %{
      "type" => "task-list",
      "title" => "Frozen",
      "snapshot" => [
        %{"title" => "Row one", "status" => "ready", "priority" => 1},
        %{"title" => "Row two", "status" => "done"}
      ]
    }

    reader = Render.render_block(legacy, @article)

    assert reader == Components.tasks_html(legacy),
           "legacy task-list no longer routes through the ONE tasks emitter byte for byte"

    # Non-vacuous: real rows made it through the emitter.
    assert String.contains?(reader, "bp-tasks"), "the frozen render is missing its row markup"
    assert String.contains?(reader, "Row one"), "the frozen render dropped a snapshot row"

    # Alias property: a snapshot-only task-list == the equivalent `tasks` block, byte
    # for byte — the widget did not fork the legacy alias.
    assert reader == Render.render_block(%{legacy | "type" => "tasks"}, @article),
           "the task-list ⇄ tasks alias drifted — the legacy render is no longer byte-identical"
  end

  test "§1 render_block(:article) is deterministic — the canvas and reader cannot differ per call" do
    # The canvas and the reader both call render_block(:article) on the SAME
    # source block. Determinism ⇒ identical input yields byte-identical output,
    # so parity holds per-call, not just per-fixture.
    for {label, block, _emitter, _sig} <-
          painted_fleet() ++ Enum.map(chip_carry(), fn {l, b, _} -> {l, b, nil, nil} end) do
      a = Render.render_block(block, @article)
      b = Render.render_block(block, @article)
      assert a == b, "#{label}: render_block(:article) is non-deterministic"
    end
  end

  # ── §2 ONE-PRODUCER STRUCTURAL (server side) ────────────────────────────────
  #
  # Each server-paint fleet block composes to a `_raw` HTML escape hatch whose
  # `html` IS the emitter output verbatim. `Walk` passes `_raw` through unchanged
  # (walk.ex `%{"kind" => "_raw"}` clause), so there is NO context-dependent
  # rendering that could make the canvas paint differ from the reader render —
  # the string is frozen at compose time. A clause that wrapped the emitter (a
  # second producer) or dropped `_raw` reds here.

  test "§2 each server-paint fleet block composes to a verbatim `_raw` node of its emitter output" do
    for {label, block, emitter, _sig} <- painted_fleet() do
      composed = Compose.compose_block(block, :article)

      assert match?(%{"kind" => "_raw", "html" => _}, composed),
             "#{label}: expected a `_raw` compose node (the single-producer escape hatch), got: #{inspect(composed)}"

      %{"html" => html} = composed

      assert html == emitter.(block),
             "#{label}: the composed `_raw` html is not the emitter output verbatim — a second producer has crept into compose"
    end
  end

  # ── §3 ONE-PRODUCER STRUCTURAL (canvas JS) — no hand-mirrored fleet markup ──
  #
  # The canvas node-view / convert JS carries blocks verbatim (bpBlock) and
  # paints the SERVER html; it must never hand-write fleet markup itself. Assert
  # NONE of the reader fleet class literals appear anywhere in the EDITOR BUNDLE
  # JS (`src/**/*.js` — node views, convert, slash menu, everything that ships;
  # `.mjs` smoke/tests are deliberately out of scope, they never reach the DOM).
  # A future node-view that hand-mirrors `<div class="bp-tasks">` (the exact D8
  # violation) reds here — in ANY source file, not just src/canvas/.

  @editor_js_glob "../../../../assets/paper-editor/src/**/*.js"

  defp editor_js_files do
    @editor_js_glob |> Path.expand(__DIR__) |> Path.wildcard()
  end

  defp editor_js_blob do
    editor_js_files()
    |> Enum.map(&File.read!/1)
    |> Enum.join("\n")
  end

  test "§3 the editor JS scan targets real, non-empty bundle sources (parser sanity)" do
    # distrust-vacuous-green: if the glob stops matching (a dir move/rename), the
    # absence assertions below pass vacuously. Anchor to files that MUST exist —
    # one per directory depth, so a glob that silently drops a depth reds — and
    # to the sanctioned mechanisms they MUST contain.
    files = editor_js_files()
    names = Enum.map(files, &Path.basename/1)

    assert "run-convert.js" in names,
           "run-convert.js not found — the editor JS scan glob is stale"

    assert "embed-node.js" in names, "embed-node.js not found — the editor JS scan glob is stale"

    assert "convert.js" in names,
           "convert.js (top-level src/) not found — the glob no longer matches depth 0"

    blob = editor_js_blob()
    assert byte_size(blob) > 0, "editor JS scan read no bytes"

    # Positive controls — the verbatim-carry + chip mechanisms this gate assumes.
    assert String.contains?(blob, "bpBlock"),
           "canvas JS no longer carries the whole block on bpBlock — the verbatim-carry contract moved; re-point this gate"

    assert String.contains?(blob, "bp-canvas-readonly"),
           "canvas JS no longer renders the read-only chip — the chip-carry contract moved; re-point this gate"
  end

  test "§3 the canvas JS hand-mirrors NO reader fleet markup (server producer is the only path)" do
    blob = editor_js_blob()

    # Reader class literals that identify a HAND-WRITTEN fleet render. The canvas
    # may only carry the block verbatim + paint server html, so none may appear.
    # The trailing list adds inner/child class families the corpus sigs don't
    # cover.
    #
    # `bp-cols__` AND `bp-term__` are deliberately NOT here: `columns` and `terminal`
    # are EDITABLE structural containers (bpColumns/bpColumn and bpTerminal node-views,
    # editable-columns / editable-terminal), NOT server-painted data mirrors. Like
    # `table` (bp-table, editable-table) and callout/code, the canvas legitimately
    # produces its `bp-cols*` / `bp-term*` markup so the user can edit INSIDE the
    # container (terminal-node.js emits bp-term__ chrome to inherit the reader paint,
    # exactly like callout emits bp-callout / table emits bp-table) — reader parity is
    # enforced by byte-aligning the node-view DOM to compose.ex, not by forbidding the
    # class here. A fleet DATA block (tasks/notes/cards/board) stays verbatim-carried
    # because editing a live-data mirror in-paper is meaningless; a layout/authored
    # container does not, so it GRADUATES out of this list the moment it becomes editable.
    #
    # `task-list` GRADUATED to EDITABLE (live-data widget, bpTaskList; task-list-node.js)
    # but STILL carries NO reader markup here: unlike columns/terminal (which emit
    # their own structural chrome to edit INSIDE), the task-list ROWS remain SERVER-
    # PAINTED (the query is the authored datum, the rows are the one server producer via
    # TaskResolver). The node-view writes ONLY `bp-canvas-tasklist-*` edit chrome and
    # paints the reader HTML into its hole — so `bp-tasks` (the reader row markup, in
    # painted_fleet's `task-list (alias)` sig) STAYS forbidden below and §3 stays green.
    # It is the figure precedent (editable caption + server-painted child), applied to a
    # LIVE QUERY + server-painted rows.
    #
    # `bp-card__` is FORBIDDEN again (S10, parity2-bug-card-slot-chrome — reverting the
    # STEP-4 graduation, whose premise model B falsified). The reader's `card_html/2`
    # (components.ex) no longer emits ANY `bp-card__*` slot chrome: slots recurse to
    # bare semantics — <h2>/<p>/<img>/a.bp-button (PRs #1529/#1539, pinned by
    # card_widget_test.exs) — so an editor `bp-card__` literal can only be a
    # HAND-WRITTEN model-A second producer (the exact WYSIWYG break S10 fixed). The
    # card node-view (card-node.js bpCard) now emits the model-B shape directly;
    # __card_parity.test.mjs pins its mounted DOM against the reader ground truth.
    # `bp-cards` (the legacy fleet GRID wrapper) stays forbidden via painted_fleet's
    # `cards` sig; the legacy fleet's own `bp-card__t`/`bp-card__d` remain reader-only
    # bytes (components.ex cards_html/1 — server-painted, verbatim-carried).
    #
    # pd-ee-dataviz-editors: the DataViz literals (bp-stat / bp-stats / bp-heat /
    # bp-chart) ride in via their painted_fleet sigs; `bp-dataviz` (the shared
    # empty-state wrapper, data_viz.ex `empty/1`) is added explicitly — the canvas
    # must never hand-write even the honest empty box (the server paints it).
    # NOTE `bp-stat` is a substring of `bp-stats`/`bp-stat__*`, so forbidding it
    # covers the whole stat class family in one contains-check.
    reader_markup =
      Enum.map(painted_fleet(), fn {_l, _b, _e, sig} -> sig end) ++
        Enum.map(chip_carry(), fn {_l, _b, sig} -> sig end) ++
        ~w(bp-tdetail bp-bcard bp-rm__ bp-pnode bp-note__ bp-momentum bp-board__ bp-card__ bp-dataviz)

    offenders =
      reader_markup
      |> Enum.uniq()
      |> Enum.filter(&String.contains?(blob, &1))

    assert offenders == [],
           """
           The canvas node-view JS hand-mirrors reader fleet markup: #{inspect(offenders)}.
           D8/rule 3: non-prose fleet blocks are painted by the reader's own
           Render.render_block/2 server-side and carried verbatim (bpBlock) — the
           canvas must NOT contain a second, hand-written HTML producer for them.
           Remove the hand-mirrored markup and paint the server html instead.
           """
  end

  # ── §4 VERBATIM-CARRY parity (sheet, embed) ─────────────────────────────────
  #
  # The chip-carry pair shows a read-only chip, not the reader render. Parity is
  # carried by the block riding VERBATIM on bpBlock (embed-node.js, zero
  # value/content ops): the saved block reader-renders identically. Assert the
  # reader render is deterministic + non-empty, and (via §3) that the canvas JS
  # shows only chip markup, never the reader's sheet/embed markup.

  test "§4 chip-carry blocks render deterministically in the reader (verbatim carry ⇒ stable bytes)" do
    for {label, block, sig} <- chip_carry() do
      a = Render.render_block(block, @article)
      b = Render.render_block(block, @article)

      assert a == b,
             "#{label}: reader render is non-deterministic — verbatim carry cannot guarantee parity"

      assert byte_size(a) > 0, "#{label}: reader render is empty"

      assert String.contains?(a, sig),
             "#{label}: reader render missing its signature markup #{inspect(sig)} — the fixture no longer exercises the emitter"
    end
  end

  # ── §5 INJECTED-DRIFT PROOF — the byte-compare has teeth ────────────────────
  #
  # Model the exact D8 violations this gate exists to catch and prove the
  # comparison reds. If these ever pass with equality, the gate is toothless (a
  # normalized/lenient compare) — this locks the compare as byte-exact.

  test "§5 a hand-mirrored class rename fails the byte-compare (teeth on §1)" do
    {_l, block, _e, _sig} = hd(painted_fleet())
    reader = Render.render_block(block, @article)

    # A canvas node-view that hand-mirrors the render but drifts one class name —
    # exactly the fork §1 catches. Byte-exact compare ⇒ MUST be unequal.
    hand_mirrored = String.replace(reader, "bp-tasks", "bp-tasks-canvas", global: false)

    refute hand_mirrored == reader,
           "the fixture no longer contains the mutated token — update the drift recipe"
  end

  test "§5 a wrapper-div second producer fails the byte-compare (teeth on §2)" do
    {_l, block, emitter, _sig} = Enum.find(painted_fleet(), fn {l, _, _, _} -> l == "cards" end)
    wrapped = ~s|<div class="canvas-fleet">| <> emitter.(block) <> "</div>"

    refute wrapped == emitter.(block),
           "wrapping the emitter output did not change the bytes — the compare is not byte-exact"
  end

  test "§5 an injected reader-markup literal would be caught by the JS scan (teeth on §3)" do
    # Prove §3's contains-check is exact: injecting a reader class into a synthetic
    # blob flips absence → present. (The LIVE recipe in the moduledoc mutates the
    # real JS file; this in-test fork proves the mechanism without touching it.)
    clean_blob = editor_js_blob()
    refute String.contains?(clean_blob, "bp-tasks"), "precondition: live editor JS must be clean"

    drifted_blob = clean_blob <> "\nconst x = '<div class=\"bp-tasks\">';\n"

    assert String.contains?(drifted_blob, "bp-tasks"),
           "the JS scan's contains-check failed to see injected markup — §3 would be toothless"
  end

  # ── §6 SECTION edit⇄reader parity — the REAL gate lives in the mjs suite ─────
  #
  # This §6 was once an EXPLICITLY WEAK text-scan (it only grepped section-node.js
  # for `gridColumn`/`order`/`data-bp-id` writes — proving the paint path was not
  # DELETED, never that the mounted shape matches the reader). The mounted-shape
  # assertions now live where they can import the node's spec + read its source in
  # pure Node: `assets/paper-editor/src/__section_parity.test.mjs` (S3 slice,
  # parity2-w1-section-gate). That mjs gate locks the `bp-section__title` binding,
  # the `bp-section__body` contentDOM, the edit-only controls (`display:none` in
  # view mode), the min-width:0 grid-cell mirror, and forbids a nested bpSection —
  # and carries a RECONCILE-or-JUSTIFY verdict for all three micro-divergences.
  #
  # A pure-Node smoke harness cannot MOUNT the NodeView (paint calls `document`),
  # so this Elixir §6 keeps ONE job: a style-write TRIPWIRE proving section-node.js
  # still mirrors per-child grid placement onto the wrapper-less item via
  # `el.style.gridColumn`/`order` keyed by `data-bp-id` (the SAME keys the reader
  # compose.ex cell_layout_attr + run-convert use), PLUS the min-width:0 cell mirror
  # this slice reconciled — a canvas that has no `.bp-section__cell` wrapper (that
  # would red §3) must carry the wrapper's resolved geometry on the item. It also
  # PINS the two-file wiring so the real gate cannot be silently unhooked.
  test "§6 section-node.js mirrors per-child grid placement + min-width onto the wrapper-less item (style-write tripwire)" do
    src =
      "../../../../assets/paper-editor/src/canvas/section-node.js"
      |> Path.expand(__DIR__)
      |> File.read!()

    assert String.contains?(src, "gridColumn"),
           "section-node.js no longer writes el.style.gridColumn — the per-child span paint moved (real regression)"

    assert String.contains?(src, ".order"),
           "section-node.js no longer writes el.style.order — the per-child order paint moved"

    assert String.contains?(src, "data-bp-id"),
           "section-node.js paint no longer keys child placement by data-bp-id — reorder-safety lost"

    assert String.contains?(src, "cells"),
           "section-node.js paint no longer reads the cells map"

    # The min-width:0 mirror of the reader's `.bp-section__cell { min-width: 0 }`
    # (compose.ex grid cell), reconciled in this slice onto the wrapper-less item.
    assert String.contains?(src, "minWidth"),
           "section-node.js no longer mirrors the reader cell's min-width:0 onto the grid item — a wide child can blow out its 1fr track (the reader can't)"

    # §3 corollary: grid mode must ride the SHARED `bp-section__grid` class (parity by
    # construction), never a hand-rolled inline grid that would fork the reader CSS.
    assert String.contains?(src, "bp-section__grid"),
           "section-node.js no longer swaps the grid body to the shared bp-section__grid class — the shared reader CSS would stop applying (a second producer)"
  end

  # ── §6b The REAL section parity gate is wired into the mjs suite ─────────────
  #
  # distrust-vacuous-green: the mounted-shape assertions only protect parity if
  # they actually RUN in CI. The paper-editor `npm test` chain (elixir.yml's asset
  # job / the paper-editor mirror job) runs the mjs suite; pin that
  # __section_parity.test.mjs EXISTS and is APPENDED to that chain, so it cannot be
  # written yet silently unhooked.
  test "§6b __section_parity.test.mjs exists and is wired into the paper-editor npm test chain" do
    base = "../../../../assets/paper-editor" |> Path.expand(__DIR__)
    test_path = Path.join(base, "src/__section_parity.test.mjs")

    assert File.exists?(test_path),
           "__section_parity.test.mjs is missing — the real section parity gate is gone"

    body = File.read!(test_path)

    # Non-vacuous: it must exercise the load-bearing bindings, not be an empty stub.
    for marker <- ["bp-section__title", "bp-section__body", "BP_SECTION_CONTENT", "minWidth"] do
      assert String.contains?(body, marker),
             "__section_parity.test.mjs no longer asserts #{marker} — the parity gate was gutted"
    end

    package_json = Path.join(base, "package.json") |> File.read!()

    assert String.contains?(package_json, "__section_parity.test.mjs"),
           "__section_parity.test.mjs is not in package.json's test chain — the real gate never runs in CI"
  end

  # ── §7 STAGE-WIDGET exemption (DESIGN 1 — the editable pipeline-node twin) ────
  #
  # The `stage` widget is EDITABLE (a bpStage control-atom node, stage-node.js), NOT a
  # server-painted verbatim fleet block — so it is DELIBERATELY absent from
  # painted_fleet (like `card`). It sidesteps the fleet gate by rendering into a
  # `bp-canvas-stage` cell whose look is hand-mirrored by CSS, NOT by emitting the
  # reader `bp-pnode` cell class. `bp-pnode` therefore STAYS in the §3 forbidden list
  # (above) so the still-verbatim-carried legacy `pipeline` fleet keeps its gate
  # protection. This test PINS that exemption: `stage` is not painted-fleet, and
  # stage-node.js introduces NONE of the forbidden reader-cell literals.

  test "§7 stage is EXEMPT from painted_fleet (editable widget, not a server-painted mirror)" do
    labels = Enum.map(painted_fleet(), fn {l, _, _, _} -> l end)

    refute "stage" in labels,
           "stage must NOT be in painted_fleet — it is an EDITABLE widget (bpStage), not a verbatim-carried fleet block"

    # The legacy pipeline stays painted-fleet + its cell class stays forbidden.
    assert "pipeline" in labels, "legacy pipeline must remain a painted-fleet block"
  end

  test "§7 stage-node.js does NOT emit the reader pipeline-cell class (bp-pnode stays gate-forbidden)" do
    src =
      "../../../../assets/paper-editor/src/canvas/stage-node.js"
      |> Path.expand(__DIR__)
      |> File.read!()

    assert byte_size(src) > 0,
           "stage-node.js not found — the DESIGN-1 exemption cannot be verified"

    refute String.contains?(src, "bp-pnode"),
           "stage-node.js emits the reader `bp-pnode` cell class — DESIGN 1 forbids it (use bp-canvas-stage)"

    assert String.contains?(src, "bp-canvas-stage"),
           "stage-node.js no longer uses the bp-canvas-stage chrome — the DESIGN-1 hook moved"
  end
end
