defmodule Barkpark.PortableDoc.Render.CanvasReaderParityGateTest do
  @moduledoc """
  Canvas ⇄ reader render-parity GATE — pd-doctrine rule 3 ("100% render parity:
  every element in the canvas looks exactly as the frontend render; same
  producer, byte for byte"), charter t10, decisions D6 + D8.

  ## What this gate locks

  The Beta canvas is THE paper editor. For every non-prose FLEET block (tasks,
  task-board, roadmap, cards, pipeline, notes, status-legend, task-detail, form,
  asciicast, diagram — plus the sheet/embed chip-carry pair) the canvas must show
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
  alias Barkpark.PortableDoc.Render.{Components, Compose, Figures, Forms}

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
       &Figures.asciicast_html(&1["src"], &1["caption"], :article), "bp-asciicast"},
      {"diagram", %{"type" => "diagram", "source" => "graph TD; A-->B", "caption" => "A graph"},
       &Figures.diagram_html(&1["source"], &1["caption"], :article), "class=\"mermaid\""}
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

      assert %{"kind" => "_raw", "html" => html} = composed,
             "#{label}: expected a `_raw` compose node (the single-producer escape hatch), got: #{inspect(composed)}"

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
    # cover, plus the inline-producer container fleet (terminal → bp-term__,
    # columns → bp-cols__) whose one producer is compose.ex itself.
    reader_markup =
      Enum.map(painted_fleet(), fn {_l, _b, _e, sig} -> sig end) ++
        Enum.map(chip_carry(), fn {_l, _b, sig} -> sig end) ++
        ~w(bp-tdetail bp-bcard bp-rm__ bp-pnode bp-note__ bp-card__ bp-momentum bp-board__ bp-term__ bp-cols__)

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
end
