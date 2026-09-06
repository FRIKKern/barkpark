defmodule BarkparkWeb.Studio.StudioLive.PaperCanvasTest do
  @moduledoc """
  Phase-4 S2 — unit tests for the PURE Studio-side canvas seam:

    * `partition_runs/1` — partition a block list into maximal contiguous prose
      runs (`{:run, blocks}`) and non-prose boundaries (`{:block, block}`).
    * `paper_canvas_enabled?/0` — the BARKPARK_PAPER_CANVAS flag, default TRUE
      (the D7/D9 cutover); only `"0"`/`"false"` opt out.
    * `run_id/1` — the stable run id (first block's id).

  No LiveView, no DB — these are the cheap, exhaustive proofs of the partition
  logic the render branch depends on.

  t6 adds the WordPress-style metadata sidebar (doctrine Rule 4/5): the pure
  seam (slug validation, the doc-field op that is NOT a block op, section
  collapse, label/relation extraction), the rendered panel (via
  `render_component`), and the "a sidebar edit never touches body blocks"
  invariant proved on the real handler.
  """
  use Barkpark.DataCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.TaskResolver
  alias BarkparkWeb.Studio.StudioLive.Components
  alias BarkparkWeb.Studio.StudioLive.Handlers.Paper, as: PaperHandler
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

  defp para(id), do: %{"id" => id, "type" => "paragraph", "content" => []}
  defp heading(id), do: %{"id" => id, "type" => "heading", "text" => "H", "level" => 2}
  defp list(id), do: %{"id" => id, "type" => "list", "ordered" => false, "items" => []}
  defp callout(id), do: %{"id" => id, "type" => "callout", "tone" => "info"}
  defp divider(id), do: %{"id" => id, "type" => "divider"}
  # RUN-SPLITTER TAIL (part 1): the 2 PICKER field-* types (field-image /
  # field-reference) are now canvas-eligible too (their WCs are client-side — no
  # LiveView dependency — so they mount inside the canvas as control-atoms). `section`
  # is now canvas-eligible too (its own bpSection CONTAINER node). Remaining run
  # boundaries include contextual form/questionnaire editors and NESTED-STRUCTURE
  # fields (composite / arrayOf / codelist / localizedText). `boundary/1` therefore
  # produces a `composite` (a still-splitting boundary); `boundary2/1` produces an
  # `arrayOf` (a SECOND distinct boundary, used where two adjacent boundaries are
  # needed). `picker/1` and `picker_ref/1` produce the now-canvas-eligible picker fields
  # used to prove they RIDE a run. `native_field/1` produces a field-string. `section/1`
  # produces the now-canvas-eligible container (with a nested child body).
  defp boundary(id), do: %{"id" => id, "type" => "composite", "fields" => [], "value" => %{}}

  defp section(id),
    do: %{"id" => id, "type" => "section", "title" => "S", "blocks" => [para(id <> "-c")]}

  defp boundary2(id), do: %{"id" => id, "type" => "arrayOf", "of" => %{}, "value" => []}
  defp picker(id), do: %{"id" => id, "type" => "field-image", "value" => ""}
  defp picker_ref(id), do: %{"id" => id, "type" => "field-reference", "value" => ""}
  defp native_field(id), do: %{"id" => id, "type" => "field-string", "value" => ""}
  # S3.6: sheet AND embed are now canvas-eligible READ-ONLY atoms (they carry the whole
  # block verbatim and never emit a value/content op), so they NO LONGER split a run.
  defp sheet(id),
    do: %{"id" => id, "type" => "sheet", "ref" => "doc/grid", "snapshot" => %{"rows" => []}}

  defp embed(id), do: %{"id" => id, "type" => "embed", "target" => "Some Note"}
  defp code(id), do: %{"id" => id, "type" => "code", "value" => ""}
  defp diagram(id), do: %{"id" => id, "type" => "diagram", "source" => "", "caption" => ""}
  # editable-action: the CTA `action` block is now a CANVAS-ELIGIBLE control-atom
  # (bpAction) — a LEAF (href/label/priority) edited by native controls, so it no
  # longer splits a run.
  defp action(id),
    do: %{
      "id" => id,
      "type" => "action",
      "href" => "https://x.test",
      "label" => "Go",
      "priority" => "primary"
    }

  # Extract + normalize a CSS selector's declaration body: the text between its `{` and
  # the next `}`, split on `;`, trimmed, empties dropped, re-joined "; ". Whitespace /
  # line-wrap insensitive, so a 2-line editor rule compares EQUAL to a wrapped reader
  # rule. Used by the view↔reader button parity assertion below.
  defp button_decls(css, selector) do
    escaped = Regex.escape(selector)

    case Regex.run(~r/#{escaped}\s*\{([^}]*)\}/, css) do
      [_, body] ->
        body
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("; ")

      _ ->
        flunk("selector not found in CSS: #{selector}")
    end
  end

  # t12a: a task-list (like every fleet kind) is now CANVAS-ELIGIBLE — it rides a
  # run as a server-painted read-only atom (bpFleet), carrying the whole block
  # verbatim. The raw block the editor mounts (and later saves) still carries its
  # live `query`, never a snapshot (D5) — folding it into a run does not resolve it.
  defp task_list(id),
    do: %{"id" => id, "type" => "task-list", "query" => %{"parent_id" => "epic"}}

  # t12a: representative FLEET kinds are canvas-eligible (server-painted
  # read-only atoms). A static fleet block carries its own data; a query fleet block
  # carries a `query`. Both ride a run verbatim.
  defp task_board(id), do: %{"id" => id, "type" => "task-board", "snapshot" => []}
  defp cards(id), do: %{"id" => id, "type" => "cards", "items" => []}
  defp fleet(id, type), do: %{"id" => id, "type" => type}

  # STEP 4: the card WIDGET — a slots-native, EDITABLE block the canvas mounts as its
  # own bpCard node, so it FOLDS INTO a run (unlike the legacy `cards` fleet grid,
  # which is verbatim-carried but ALSO canvas-eligible). Distinct type from `cards`.
  defp card_widget(id),
    do: %{
      "id" => id,
      "type" => "card",
      "tone" => "info",
      "slots" => %{
        "title" => [%{"type" => "heading", "text" => "Card"}],
        "body" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "hi"}]}]
      }
    }

  # The stub fetcher the Studio wiring hands TaskResolver.preview/2 (Shared.
  # task_previews wires the real Tasks.Query fetcher; here we prove the two-
  # channel SEPARATION, not the DB).
  defp task_rows(%{"parent_id" => "epic"}), do: [%{"title" => "a", "status" => "ready"}]
  defp task_rows(_), do: []

  describe "partition_runs/1" do
    test "empty list → []" do
      assert PaperCanvas.partition_runs([]) == []
    end

    test "all-prose → a single maximal run" do
      blocks = [heading("h1"), para("p1"), list("l1"), para("p2")]
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "no canvas blocks → every block is its own boundary segment" do
      # divider/callout/code IS canvas; sheet/embed are (S3.6); the 7 native field-*
      # types AND the 2 PICKER fields are (run-splitter tail). So this all-boundary case
      # uses the NESTED-STRUCTURE fields (composite / arrayOf) — the only remaining run
      # boundaries.
      blocks = [boundary("f1"), boundary2("r1")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:block, boundary("f1")},
               {:block, boundary2("r1")}
             ]
    end

    # ── S3: the divider is CANVAS-ELIGIBLE — it no longer splits a run ──────────

    test "S3: a divider INSIDE prose keeps the run whole (was split by the divider)" do
      blocks = [heading("h1"), para("p1"), divider("d1"), para("p2")]

      # All four are canvas-eligible (prose ∪ divider) ⇒ ONE maximal run.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    # ── S3.2: the callout is now CANVAS-ELIGIBLE too — it no longer splits ──────

    test "S3.2: a callout INSIDE prose keeps the run whole (was split by the callout)" do
      blocks = [para("p1"), callout("c1"), para("p2")]

      # All three are canvas-eligible (prose ∪ callout) ⇒ ONE maximal run.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "TAIL: the PICKER fields (field-image / field-reference) now RIDE a run (no longer split)" do
      # Run-splitter tail (part 1): both pickers mount client-side WCs inside the canvas,
      # so a picker between two prose blocks is ONE maximal run — it no longer splits.
      for pkr <- [picker("img"), picker_ref("ref")] do
        blocks = [para("p1"), pkr, para("p2")]

        assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}],
               "expected #{pkr["type"]} to RIDE the run (canvas-eligible)"
      end
    end

    test "TAIL: ONLY the NESTED-STRUCTURE fields STILL split a run" do
      # Everything common is canvas now (prose, divider, callout, code, diagram, the 7
      # native field-* types, the 2 pickers, sheet, embed, the fleet kinds, AND the
      # `section` CONTAINER) — so the ONLY still-splitting boundaries are the remaining
      # nested-structure fields (composite / arrayOf / codelist / localizedText).
      # `section` is DELIBERATELY absent here — it rides its own bpSection container
      # node now (see the section-rides-a-run test below).
      for boundary <- [
            %{"id" => "b", "type" => "composite", "fields" => [], "value" => %{}},
            %{"id" => "b", "type" => "arrayOf", "of" => %{}, "value" => []},
            %{"id" => "b", "type" => "codelist", "value" => ""},
            %{"id" => "b", "type" => "localizedText", "value" => %{}}
          ] do
        blocks = [para("p1"), boundary, para("p2")]

        assert PaperCanvas.partition_runs(blocks) == [
                 {:run, [para("p1")]},
                 {:block, boundary},
                 {:run, [para("p2")]}
               ],
               "expected #{boundary["type"]} to split the run"
      end
    end

    # ── the `section` CONTAINER is now CANVAS-ELIGIBLE — it folds INTO a run ──────

    test "STEP 4: a card WIDGET rides a run (canvas-eligible), distinct from a fleet boundary" do
      # A card folds INTO the run alongside prose (bpCard node), like the section
      # container — NOT a run boundary. The legacy `cards` fleet also rides (verbatim),
      # so a card + a legacy cards grid + prose are ONE maximal run.
      blocks = [para("p1"), card_widget("cw1"), para("p2")]
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]

      mixed = [para("p1"), card_widget("cw1"), cards("c1"), para("p2")]
      assert PaperCanvas.partition_runs(mixed) == [{:run, mixed}]

      # And a lone card is a single run, never a boundary.
      assert PaperCanvas.partition_runs([card_widget("only")]) == [{:run, [card_widget("only")]}]
    end

    test "notes-grid split: a NOTE widget rides a run (canvas content node), distinct from the `notes` fleet grid" do
      # A note is a CONTENT node (@canvas_content_types, alongside callout) — it FOLDS
      # INTO a run. The plural `notes` fleet grid ALSO rides (verbatim), so a note + a
      # legacy notes grid + prose are ONE maximal run.
      note = %{"id" => "nw1", "type" => "note", "label" => "l", "text" => "b"}
      notes = %{"id" => "ns1", "type" => "notes", "items" => []}

      blocks = [para("p1"), note, para("p2")]
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]

      mixed = [para("p1"), note, notes, para("p2")]
      assert PaperCanvas.partition_runs(mixed) == [{:run, mixed}]

      # And a lone note is a single run, never a boundary.
      assert PaperCanvas.partition_runs([note]) == [{:run, [note]}]
    end

    test "section: a section is a contextual boundary between prose runs" do
      blocks = [para("p1"), section("sec1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, section("sec1")},
               {:run, [para("p2")]}
             ]
    end

    test "section: splits a heading run from the following paragraph run" do
      blocks = [heading("h1"), section("sec1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [heading("h1")]},
               {:block, section("sec1")},
               {:run, [para("p2")]}
             ]
    end

    test "section: canvas? is false for contextual Section and composite boundaries" do
      refute PaperCanvas.canvas?(section("sec1"))
      refute PaperCanvas.canvas?(boundary("b1"))
    end

    test "section: a lone section is a contextual boundary" do
      assert PaperCanvas.partition_runs([section("only")]) == [{:block, section("only")}]
    end

    test "section: remains distinct beside another nested-structure boundary" do
      blocks = [para("p1"), section("sec1"), boundary("b1"), section("sec2"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, section("sec1")},
               {:block, boundary("b1")},
               {:block, section("sec2")},
               {:run, [para("p2")]}
             ]
    end

    # ── S3.6: sheet AND embed are now CANVAS-ELIGIBLE read-only atoms — no split ──

    test "S3.6: a sheet INSIDE prose keeps the run whole (was split by the sheet)" do
      blocks = [para("p1"), sheet("s1"), para("p2")]

      # All three are canvas-eligible (prose ∪ sheet read-only atom) ⇒ ONE maximal run.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "S3.6: an embed INSIDE prose keeps the run whole (was split by the embed)" do
      blocks = [para("p1"), embed("e1"), para("p2")]

      # All three are canvas-eligible (prose ∪ embed read-only atom) ⇒ ONE maximal run.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "S3.6: [paragraph, sheet, embed, paragraph] is ONE run (both read-only atoms ride)" do
      blocks = [para("p1"), sheet("s1"), embed("e1"), para("p2")]

      # sheet AND embed are both canvas-eligible read-only atoms, so the whole stretch
      # is ONE maximal run — neither splits.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "TAIL: a nested-structure boundary splits while sheet+embed+picker ride it" do
      # A composite (nested-structure) field between two runs is the ONLY split point;
      # sheet, embed, AND a picker (field-image) all RIDE their surrounding runs.
      blocks = [para("p1"), sheet("s1"), picker("img"), boundary("cmp"), embed("e1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1"), sheet("s1"), picker("img")]},
               {:block, boundary("cmp")},
               {:run, [embed("e1"), para("p2")]}
             ]
    end

    test "S3.6: mixed sheet + embed + code + callout in ONE run (all canvas-eligible)" do
      blocks = [
        para("p1"),
        sheet("s1"),
        embed("e1"),
        code("k1"),
        callout("c1"),
        para("p2")
      ]

      # sheet/embed (read-only atoms) AND code (attr-atom) AND callout (content) are ALL
      # canvas-eligible, so the whole stretch is ONE maximal run — none split.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    # ── t12a: contextual FLEET kinds are CANVAS-ELIGIBLE — they no longer split ──

    test "t12a: every fleet kind INSIDE prose keeps the run whole (was a boundary widget)" do
      # These fleet types are canvas-eligible (server-painted read-only atoms), so each
      # rides the prose run rather than splitting it. Form and questionnaire are tested
      # below as contextual boundaries. `diagram` rides its own editable attr-atom.
      for type <-
            ~w(tasks task-list task-detail task-board roadmap notes cards pipeline status-legend asciicast) do
        blk = fleet("x1", type)
        blocks = [para("p1"), blk, para("p2")]

        assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}],
               "expected #{type} to ride the run (canvas-eligible)"
      end
    end

    test "t12a: [heading, task-board, paragraph] is ONE run (the fleet block no longer splits)" do
      blocks = [heading("h1"), task_board("b1"), para("p1")]

      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "t12a: a fleet block folds into a run but rides VERBATIM (raw, no snapshot injected — D5)" do
      blocks = [para("p1"), task_list("t1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
      # The block is unchanged by partitioning — its live query is intact, no
      # snapshot leaked in. The save baseline the canvas diffs is byte-identical.
      assert Enum.at(blocks, 1)["query"] == %{"parent_id" => "epic"}
      refute Map.has_key?(Enum.at(blocks, 1), "snapshot")
    end

    test "t12a: a fleet block + sheet + code + callout in ONE run (all canvas-eligible)" do
      blocks = [para("p1"), cards("c1"), sheet("s1"), code("k1"), callout("cl1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "t12a: a nested-structure boundary still splits while fleet blocks ride each run" do
      # A composite (nested-structure) field is STILL a boundary; the fleet blocks
      # (task-board, cards) ride the prose runs on either side of it.
      blocks = [para("p1"), task_board("b1"), boundary("cmp"), cards("c1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1"), task_board("b1")]},
               {:block, boundary("cmp")},
               {:run, [cards("c1"), para("p2")]}
             ]
    end

    test "t12a: a lone fleet block is a single run, not a boundary" do
      assert PaperCanvas.partition_runs([task_board("b1")]) == [{:run, [task_board("b1")]}]
    end

    test "contextual authoring: form and questionnaire are boundaries, not canvas fleet atoms" do
      refute PaperCanvas.canvas?(fleet("form-1", "form"))
      refute PaperCanvas.canvas?(fleet("questionnaire-1", "questionnaire"))
    end

    test "contextual authoring: alternating prose and form/questionnaire boundaries stay distinct" do
      form = fleet("form-1", "form")
      questionnaire = fleet("questionnaire-1", "questionnaire")

      assert PaperCanvas.partition_runs([
               para("p1"),
               form,
               para("p2"),
               questionnaire,
               para("p3")
             ]) == [
               {:run, [para("p1")]},
               {:block, form},
               {:run, [para("p2")]},
               {:block, questionnaire},
               {:run, [para("p3")]}
             ]
    end

    # ── pd-ee-dataviz-editors: the 5 DATA-VIZ kinds are CANVAS-ELIGIBLE (D3) ──

    test "dataviz: every data-viz kind INSIDE prose keeps the run whole (was the :1339 catch-all)" do
      # stat / stats / stat-grid / heatmap / chart fold into runs as server-painted
      # bpFleet atoms (@canvas_dataviz_types, a parallel painted-set — the block
      # rides verbatim, display HTML arrives via push_block_renders' bp:block-html).
      # `stat-grid` is the accepted alias of `stats`; both are enumerated.
      for type <- ~w(stat stats stat-grid heatmap chart) do
        blk = fleet("dv1", type)
        blocks = [para("p1"), blk, para("p2")]

        assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}],
               "expected #{type} to ride the run (canvas-eligible)"

        assert PaperCanvas.canvas?(blk), "expected canvas?(#{type}) to be true"
      end
    end

    test "dataviz: a stat block folds into a run as a painted boundary node, VERBATIM (D5)" do
      stat = %{
        "id" => "st1",
        "type" => "stat",
        "value" => "71",
        "label" => "tests",
        "max" => 118,
        "spark" => [1, 2, 3]
      }

      blocks = [heading("h1"), stat, para("p1")]
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]

      # The block is untouched by partitioning — the authored config (the save
      # baseline the canvas diffs, and the payload the JSON island edits) rides
      # verbatim; the paint never mutates the block (display-only, D5).
      assert Enum.at(blocks, 1) == stat
    end

    test "dataviz: a data-viz block next to a nested-structure boundary still splits at the boundary only" do
      chart = %{"id" => "ch1", "type" => "chart", "series" => [%{"points" => [1, 2]}]}
      blocks = [para("p1"), chart, boundary("cmp"), fleet("hm1", "heatmap"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1"), chart]},
               {:block, boundary("cmp")},
               {:run, [fleet("hm1", "heatmap"), para("p2")]}
             ]
    end

    # ── Contextual Columns/Section boundaries host nested canvas runs ──

    test "a columns block inside prose splits into its contextual editor" do
      cols = %{
        "id" => "c1",
        "type" => "columns",
        "columns" => [[%{"type" => "paragraph"}], [%{"type" => "paragraph"}]]
      }

      blocks = [para("p1"), cols, para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, cols},
               {:run, [para("p2")]}
             ]

      refute PaperCanvas.canvas?(cols)
    end

    test "a lone columns block is a contextual boundary" do
      cols = %{"id" => "c1", "type" => "columns", "columns" => [[%{"type" => "paragraph"}]]}
      assert PaperCanvas.partition_runs([cols]) == [{:block, cols}]
    end

    test "Section is routed to its contextual boundary" do
      sec = %{"id" => "b", "type" => "section", "title" => "S", "blocks" => [para("b-c")]}

      assert PaperCanvas.partition_runs([para("p1"), sec, para("p2")]) ==
               [{:run, [para("p1")]}, {:block, sec}, {:run, [para("p2")]}]

      composite = %{"id" => "cmp", "type" => "composite"}

      assert PaperCanvas.partition_runs([para("p1"), composite, para("p2")]) == [
               {:run, [para("p1")]},
               {:block, composite},
               {:run, [para("p2")]}
             ],
             "expected composite to STAY a boundary"
    end

    # ── S3.5: the 7 NATIVE field-* types are now CANVAS-ELIGIBLE — they no longer split ──

    test "S3.5: a native field block INSIDE prose keeps the run whole (was split by the field)" do
      # All 7 native field-* types are canvas-eligible (control-atoms), so each rides
      # the prose run rather than splitting it.
      for type <-
            ~w(field-string field-slug field-text field-boolean field-select field-datetime field-color) do
        fld = %{"id" => "x1", "type" => type, "value" => ""}
        blocks = [para("p1"), fld, para("p2")]

        assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}],
               "expected #{type} to ride the run (canvas-eligible)"
      end
    end

    test "TAIL: a native field AND a picker field both join ONE run; a nested-structure field STILL splits" do
      # native_field (field-string) AND picker (field-image) are BOTH canvas now.
      assert PaperCanvas.partition_runs([para("p1"), native_field("n1"), para("p2")]) ==
               [{:run, [para("p1"), native_field("n1"), para("p2")]}]

      assert PaperCanvas.partition_runs([para("p1"), picker("img"), para("p2")]) ==
               [{:run, [para("p1"), picker("img"), para("p2")]}]

      # Only a nested-structure field (composite) still splits.
      split = [para("p1"), boundary("cmp"), para("p2")]

      assert PaperCanvas.partition_runs(split) == [
               {:run, [para("p1")]},
               {:block, boundary("cmp")},
               {:run, [para("p2")]}
             ]
    end

    test "S3.5: a native field + code + callout + diagram in ONE run (all canvas-eligible)" do
      blocks = [
        para("p1"),
        native_field("n1"),
        code("k1"),
        callout("c1"),
        diagram("g1"),
        para("p2")
      ]

      # native field (control-atom) AND code/diagram (attr-atoms) AND callout (content)
      # are ALL canvas-eligible, so the whole stretch is ONE maximal run — none split.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "TAIL: a picker field + a native field + code in ONE run (all canvas-eligible)" do
      blocks = [
        para("p1"),
        picker("img"),
        picker_ref("ref"),
        native_field("n1"),
        code("k1"),
        para("p2")
      ]

      # picker fields (control-atoms mounting WCs) AND the native field (control-atom)
      # AND code (attr-atom) are ALL canvas-eligible, so the whole stretch is ONE maximal
      # run — none split.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    # ── S3.3: the code block is now CANVAS-ELIGIBLE too — it no longer splits ────

    test "S3.3: a code block INSIDE prose keeps the run whole (was split by the code)" do
      blocks = [para("p1"), code("k1"), para("p2")]

      # All three are canvas-eligible (prose ∪ code attr-atom) ⇒ ONE maximal run.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    # ── S3.4: the diagram block is now CANVAS-ELIGIBLE too — it no longer splits ──

    test "S3.4: a diagram block INSIDE prose keeps the run whole (was split by the diagram)" do
      blocks = [para("p1"), diagram("g1"), para("p2")]

      # All three are canvas-eligible (prose ∪ diagram attr-atom) ⇒ ONE maximal run.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    # ── editable-action: the CTA action block is now CANVAS-ELIGIBLE — no split ──

    test "editable-action: an action block INSIDE prose keeps the run whole (was a boundary)" do
      blocks = [para("p1"), action("a1"), para("p2")]

      # All three are canvas-eligible (prose ∪ action control-atom) ⇒ ONE maximal run.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
      assert PaperCanvas.canvas?(action("a1"))
    end

    test "editable-action: a lone action block is a single run, not a boundary" do
      assert PaperCanvas.partition_runs([action("a1")]) == [{:run, [action("a1")]}]
    end

    test "S3.2: mixed callout + divider in ONE run (both canvas-eligible)" do
      blocks = [para("p1"), callout("c1"), divider("d1"), para("p2")]

      # callout (content node) AND divider (atom) are both canvas-eligible, so the
      # whole stretch is ONE maximal run — neither splits.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "S3.3: mixed code + divider + callout in ONE run (all canvas-eligible)" do
      blocks = [para("p1"), code("k1"), divider("d1"), callout("c1"), para("p2")]

      # code (attr-atom) AND divider (atom) AND callout (content) are ALL
      # canvas-eligible, so the whole stretch is ONE maximal run — none split.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "S3.4: mixed diagram + code + callout in ONE run (all canvas-eligible)" do
      blocks = [para("p1"), diagram("g1"), code("k1"), callout("c1"), para("p2")]

      # diagram (attr-atom) AND code (attr-atom) AND callout (content) are ALL
      # canvas-eligible, so the whole stretch is ONE maximal run — none split.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "S3: a LEADING divider opens a run (canvas-eligible, joins the following prose)" do
      blocks = [divider("d1"), para("p1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "S3: a TRAILING divider stays in the run (does not break off)" do
      blocks = [para("p1"), heading("h1"), divider("d1")]

      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "S3: a run of ONLY [divider] is a single run, not a boundary" do
      blocks = [divider("d1")]

      assert PaperCanvas.partition_runs(blocks) == [{:run, [divider("d1")]}]
    end

    test "S3.2: a divider directly AFTER a callout stays in ONE run (both canvas)" do
      # As of S3.2 the callout is canvas-eligible too, so [p, callout, divider, p]
      # is a single maximal run — the callout no longer breaks it.
      blocks = [para("p1"), callout("c1"), divider("d1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "TAIL: a nested-structure boundary splits, with a callout (and a picker) riding each surrounding run" do
      # composite (a nested-structure field) is still a boundary; the callouts AND the
      # pickers are canvas, so each rides the prose run on its side of the boundary.
      blocks = [
        para("p1"),
        callout("c1"),
        picker("img"),
        boundary("cmp"),
        callout("c2"),
        para("p2")
      ]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1"), callout("c1"), picker("img")]},
               {:block, boundary("cmp")},
               {:run, [callout("c2"), para("p2")]}
             ]
    end

    test "mixed list → maximal runs split by NON-CANVAS boundaries, order preserved" do
      blocks = [
        heading("h1"),
        para("p1"),
        callout("c1"),
        para("p2"),
        list("l1"),
        divider("d1"),
        picker("img"),
        boundary("cmp"),
        para("p3")
      ]

      # Neither the callout NOR the divider NOR the picker splits — they ride the
      # leading run; only the nested-structure field (composite) splits it off from p3.
      assert PaperCanvas.partition_runs(blocks) == [
               {:run,
                [
                  heading("h1"),
                  para("p1"),
                  callout("c1"),
                  para("p2"),
                  list("l1"),
                  divider("d1"),
                  picker("img")
                ]},
               {:block, boundary("cmp")},
               {:run, [para("p3")]}
             ]
    end

    test "leading non-canvas then a run" do
      # composite is a boundary (callout/picker are canvas, so they would merge).
      blocks = [boundary("cmp"), para("p1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:block, boundary("cmp")},
               {:run, [para("p1"), para("p2")]}
             ]
    end

    test "two non-canvas boundaries between two runs do NOT merge into one run" do
      # composite + arrayOf — both still NESTED-STRUCTURE boundaries (callout/divider/
      # sheet/embed/pickers are all canvas now).
      blocks = [para("p1"), boundary("cmp"), boundary2("arr"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, boundary("cmp")},
               {:block, boundary2("arr")},
               {:run, [para("p2")]}
             ]
    end

    test "a block missing a type is treated as a non-canvas boundary" do
      blocks = [para("p1"), %{"id" => "x"}, para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, %{"id" => "x"}},
               {:run, [para("p2")]}
             ]
    end
  end

  describe "prose?/1" do
    test "paragraph / heading / list are prose; everything else (incl. divider, callout) is not" do
      assert PaperCanvas.prose?(para("p"))
      assert PaperCanvas.prose?(heading("h"))
      assert PaperCanvas.prose?(list("l"))
      # A callout is canvas-eligible (S3.2) but NOT prose — it is a content node
      # with its own chrome, not a bare textblock.
      refute PaperCanvas.prose?(callout("c"))
      # A divider is canvas-eligible but NOT prose — it is an atom, not a textblock.
      refute PaperCanvas.prose?(divider("d"))
      # A picker field is canvas-eligible (control-atom) but NOT prose.
      refute PaperCanvas.prose?(picker("f"))
      # A composite is neither prose nor canvas.
      refute PaperCanvas.prose?(boundary("b"))
      refute PaperCanvas.prose?(%{"id" => "x"})
      refute PaperCanvas.prose?(%{"type" => "code"})
    end
  end

  describe "canvas?/1 (TAIL: prose ∪ divider ∪ callout ∪ code ∪ diagram ∪ native ∪ picker fields ∪ sheet ∪ embed)" do
    test "prose/divider/callout/code/diagram/native fields/picker fields/sheet/embed are canvas; nested-structure fields are not" do
      assert PaperCanvas.canvas?(para("p"))
      assert PaperCanvas.canvas?(heading("h"))
      assert PaperCanvas.canvas?(list("l"))
      # S3: a divider is canvas-eligible (an atom node inside the run).
      assert PaperCanvas.canvas?(divider("d"))
      # S3.2: a callout is canvas-eligible (a content node with an editable body).
      assert PaperCanvas.canvas?(callout("c"))
      # S3.3: a code block is canvas-eligible (an attr-atom: value/lang in attrs,
      # edited by a non-PM textarea island).
      assert PaperCanvas.canvas?(code("k"))
      # S3.4: a diagram block is canvas-eligible (an attr-atom: source/caption in
      # attrs, edited by a non-PM textarea island — mirrors the code shape).
      assert PaperCanvas.canvas?(diagram("g"))

      # S3.5: each of the 7 NATIVE field-* types is canvas-eligible (a control-atom:
      # value in an attr, edited by a native control, coerced by field type).
      for type <-
            ~w(field-string field-slug field-text field-boolean field-select field-datetime field-color) do
        assert PaperCanvas.canvas?(%{"id" => "f", "type" => type, "value" => ""}),
               "expected #{type} to be canvas-eligible"
      end

      # S3.6: sheet AND embed are canvas-eligible (read-only atoms carrying the whole
      # block verbatim; they never emit a value/content op).
      assert PaperCanvas.canvas?(sheet("s"))
      assert PaperCanvas.canvas?(embed("e"))

      # TAIL: the 2 PICKER fields are canvas-eligible (control-atoms mounting client-side
      # picker WCs; coerced/patched as { value } like the native fields).
      assert PaperCanvas.canvas?(picker("f"))
      assert PaperCanvas.canvas?(picker_ref("fr"))

      # t12a: each contextual fleet kind is canvas-eligible (server-painted read-only
      # atoms carrying the whole block verbatim on bpFleet). `diagram` is NOT a fleet
      # type — it stays an attr-atom (asserted canvas above via its own clause). Form
      # and questionnaire deliberately remain contextual boundary editors.
      for type <-
            ~w(tasks task-list task-detail task-board roadmap notes cards pipeline status-legend asciicast) do
        assert PaperCanvas.canvas?(fleet("f", type)), "expected #{type} to be canvas-eligible"
      end

      refute PaperCanvas.canvas?(fleet("form", "form"))
      refute PaperCanvas.canvas?(fleet("questionnaire", "questionnaire"))

      # The NESTED-STRUCTURE fields stay run boundaries too.
      refute PaperCanvas.canvas?(boundary("cmp"))
      refute PaperCanvas.canvas?(boundary2("arr"))
      refute PaperCanvas.canvas?(%{"id" => "x"})
    end
  end

  describe "run_id/2 (Bug #1a: keyed by ORDINAL, not first-block id; Bug #1c: slug-namespaced)" do
    test "is slug <> \"-run-\" <> ordinal — a STABLE string id, NOT the first block's id" do
      # Run identity WITHIN a paper is the run's ORDINAL in partition_runs output,
      # not its mutable first-block id. (Previously run_id([first | _]) returned
      # first["id"], which changed when a run's leading block was deleted — the bug.)
      assert PaperCanvas.run_id("my-paper", 0) == "my-paper-run-0"
      assert PaperCanvas.run_id("my-paper", 1) == "my-paper-run-1"
      assert PaperCanvas.run_id("my-paper", 7) == "my-paper-run-7"
    end

    test "the id is namespaced by the paper slug so ids never collide ACROSS papers (Bug #1c)" do
      # A bare-ordinal id ("run-0") is identical for every paper; morphdom's global
      # keyed-node reuse then transplants the OLD paper's phx-update="ignore" wrapper
      # into the NEW paper's editor on a patch-navigation — the stuck-paper bug. The
      # slug prefix makes the id change on navigation → remove+add → fresh mount.
      refute PaperCanvas.run_id("paper-a", 0) == PaperCanvas.run_id("paper-b", 0)
      assert PaperCanvas.run_id("paper-a", 0) == PaperCanvas.run_id("paper-a", 0)
    end

    test "the id is a non-empty STRING so the hook's `!run.run_id` guard never drops run 0" do
      # The inbound hook guards `if (!run.run_id) return;`. A bare integer 0 would be
      # falsy → the FIRST run's echo silently dropped. The slug + "-run-" prefix makes
      # every ordinal id truthy.
      assert PaperCanvas.run_id("my-paper", 0) == "my-paper-run-0"
      assert is_binary(PaperCanvas.run_id("my-paper", 0))
      refute PaperCanvas.run_id("my-paper", 0) == ""
    end
  end

  describe "with_run_ordinals/1 (Bug #1a: single source of truth for run ordinals)" do
    test "stamps each {:run, _} with a sequential ordinal; {:block, _} passes through" do
      # Two runs separated by a nested-structure boundary → run ordinals 0 and 1, with
      # the {:block, _} boundary carrying no ordinal.
      segments = [
        {:run, [para("p1"), para("p2")]},
        {:block, boundary("cmp1")},
        {:run, [heading("h1")]}
      ]

      assert PaperCanvas.with_run_ordinals(segments) == [
               {:run, [para("p1"), para("p2")], 0},
               {:block, boundary("cmp1")},
               {:run, [heading("h1")], 1}
             ]
    end

    test "ordinal is STABLE under a leading-block delete (the Bug #1a invariant)" do
      # A run's first block changing (leading-block delete/merge) does NOT shift the
      # run's ordinal — it stays at the same index in partition_runs output. So the
      # wrapper id (run_id(slug, ordinal)) is unchanged → no remount, echo still
      # matches.
      before = PaperCanvas.partition_runs([para("p1"), para("p2"), para("p3")])
      after_del = PaperCanvas.partition_runs([para("p2"), para("p3")])

      [{:run, _, ord_before}] = PaperCanvas.with_run_ordinals(before)
      [{:run, _, ord_after}] = PaperCanvas.with_run_ordinals(after_del)

      assert ord_before == 0
      assert ord_after == 0

      assert PaperCanvas.run_id("my-paper", ord_before) ==
               PaperCanvas.run_id("my-paper", ord_after)
    end
  end

  describe "live task-block preview (t9) — parallel channel, save-stable (D5)" do
    test "t12a: the block the editor mounts rides the run as a RAW query block — no snapshot injected" do
      blocks = [para("p1"), task_list("t1"), para("p2")]

      # t12a flip: the task block is now canvas-eligible, so it folds INTO the run
      # (server-painted in-canvas via bpFleet) instead of splitting into its own
      # boundary widget. It still rides VERBATIM — raw query, no snapshot (D5).
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
      assert Enum.at(blocks, 1)["query"] == %{"parent_id" => "epic"}
      refute Map.has_key?(Enum.at(blocks, 1), "snapshot")
    end

    test "resolving the preview leaves the mounted/saved blocks BYTE-IDENTICAL → an untouched save emits ZERO ops" do
      # The exact block list the editor mounts (its save baseline).
      baseline = [para("p1"), task_list("t1"), para("p2")]

      # Computing the live preview (the parallel display channel) must NOT mutate
      # the baseline: the previews come out on the side, keyed by block id.
      previews = TaskResolver.preview(baseline, &task_rows/1)

      assert previews == [
               %{
                 "block_id" => "t1",
                 "type" => "task-list",
                 "snapshot" => [%{"title" => "a", "status" => "ready"}]
               }
             ]

      # The baseline is unchanged — the task block still holds its raw `query`,
      # no `snapshot` leaked in. run-convert.js keys runToOps on THESE blocks, so
      # a save with no author edit diffs identical source → an empty op batch.
      assert baseline == [para("p1"), task_list("t1"), para("p2")]
      assert Enum.at(baseline, 1)["query"] == %{"parent_id" => "epic"}
      refute Map.has_key?(Enum.at(baseline, 1), "snapshot")
    end
  end

  describe "t12a flip — the flag-ON paper pane rides fleet blocks IN-CANVAS (no boundary widget)" do
    alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

    # The flag-ON editor render for the PAPER PANE (canvas_eligible). Static
    # function-component render — no LiveView process, no DB.
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

    defp editor_html(blocks, previews) do
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "p1",
        blocks: blocks,
        canvas_eligible: true,
        task_previews: previews
      )
    end

    defp run_count(html), do: length(String.split(html, ~s(data-test-id="paper-canvas-run"))) - 1

    test "a query fleet block (task-list) now rides ONE canvas run, NOT a boundary widget (D5 verbatim)" do
      html = editor_html([para("p1"), task_list("t1"), para("p2")], %{})

      # The flip: the fleet block folded INTO the run, so it paints in-canvas via
      # the bpFleet node-view (+ push_block_renders' bp:block-html) — it no longer
      # falls through to the per-block boundary widget.
      refute html =~ ~s(data-test-id="paper-task-preview"),
             "a top-level fleet block must NOT render a boundary widget in the flag-ON paper pane"

      # The whole doc is ONE canvas run carrying the block verbatim (D5): its raw
      # query rides into the seed, and no resolved snapshot is ever serialized in.
      assert run_count(html) == 1
      assert html =~ ~s(data-canvas-blocks)
      assert html =~ "task-list"
      assert html =~ "parent_id"
      refute html =~ ~s(&quot;snapshot&quot;)
    end

    test "a STATIC fleet block (cards) also rides the run, not a boundary widget" do
      html = editor_html([heading("h1"), cards("c1"), para("p1")], %{})

      refute html =~ ~s(data-test-id="paper-task-preview")
      assert run_count(html) == 1
      assert html =~ ~s(data-canvas-blocks)
      assert html =~ "cards"
    end

    test "a nested-structure boundary still splits fleet-bearing runs into TWO canvas runs" do
      # composite is still a boundary; the task-board and cards ride the runs on
      # either side — so two canvas runs render, with the composite between them on
      # its own per-block widget.
      html =
        editor_html(
          [para("p1"), task_board("b1"), boundary("cmp"), cards("c1"), para("p2")],
          %{}
        )

      assert run_count(html) == 2
      refute html =~ ~s(data-test-id="paper-task-preview")
      # the composite boundary still renders its own per-block edit row
      assert html =~ ~s(data-edit-block-id="cmp")
    end
  end

  describe "sup-w5 — the footer echoes the REAL save_status (no more hardcoded '✓ Auto-saved' lie)" do
    alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

    defp save_footer(save_status, paper_halt \\ nil) do
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "p-save",
        blocks: [para("p1")],
        canvas_eligible: true,
        save_status: save_status,
        paper_halt: paper_halt
      )
    end

    # THE non-vacuous guard: reverting the footer to the literal "✓ Auto-saved"
    # makes THIS fail — a "Save failed" write can only surface verbatim if the
    # footer actually reads @save_status.
    test "a 'Save failed' status is echoed verbatim in the footer save region" do
      html = save_footer("Save failed")

      assert html =~ ~s(data-test-id="bp-paper-footer-save")
      assert html =~ "Save failed"
      # the old hardcoded calm token must NOT appear when the write failed
      refute html =~ "✓ Auto-saved"
    end

    test "the calm 'Auto-saved' token keeps its premium ✓ affix" do
      html = save_footer("Auto-saved")
      assert html =~ "✓ Auto-saved"
    end

    test "a fresh pre-write open (unassigned save_status ⇒ \"\") shows an empty, non-lying save region" do
      html = save_footer("")
      # the region is present and accessible, but carries no false 'Auto-saved'
      assert html =~ ~s(data-test-id="bp-paper-footer-save")
      refute html =~ "Auto-saved"
      refute html =~ "Save failed"
    end

    test "the save region is an accessible live status (role=status, aria-live=polite)" do
      html = save_footer("Auto-saved")
      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
    end

    test "a paper_halt reason raises the shared server-truth banner near the top" do
      reason = "document is hollow — add a content block beyond the title"
      html = save_footer("Save failed", reason)

      assert html =~ ~s(data-test-id="paper-halt-banner")
      assert html =~ reason
    end

    test "no paper_halt ⇒ no banner (a clean edit renders nothing)" do
      html = save_footer("Auto-saved", nil)
      refute html =~ ~s(data-test-id="paper-halt-banner")
    end
  end

  describe "task_block_preview/1 — retained boundary widget still paints the reader's producer (D8/rule 3)" do
    alias Barkpark.PortableDoc.Render
    alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

    # t12a: after the partition flip a fleet block no longer reaches this widget in
    # the paper pane (it rides a run). The widget is RETAINED infra (deletion is a
    # wave-4/human step), so its painting contract is proven by rendering the
    # component DIRECTLY — the reader-producer parity (rule 3) that the in-canvas
    # bpFleet paint also inherits, since both call Render.render_block/2.
    defp preview_html(block, preview) do
      render_component(&PaperEditor.task_block_preview/1, block: block, preview: preview)
    end

    test "a resolved preview renders through the READER'S producer (rule 3), display-only (D5)" do
      block = task_list("t1")

      entry = %{
        "block_id" => "t1",
        "type" => "task-list",
        "snapshot" => [%{"title" => "Ship the seam", "status" => "ready"}]
      }

      html = preview_html(block, entry)

      # The widget paints the live rows…
      assert html =~ ~s(data-test-id="paper-task-preview")
      assert html =~ "Ship the seam"

      # …as the EXACT bytes /papers would emit for the resolved block — one
      # producer, byte for byte (doctrine rule 3). The same producer the in-canvas
      # bpFleet atom paints, so parity is shared.
      resolved = TaskResolver.apply_preview(block, entry)
      assert html =~ Render.render_block(resolved, %{style: :article})

      # D5: the widget never serializes the resolved snapshot back — it renders the
      # display HTML off a COPY, the source block is untouched.
      refute html =~ ~s(&quot;snapshot&quot;)
    end

    test "an error entry degrades to the quiet plugin-off note" do
      entry = %{"block_id" => "t1", "type" => "task-list", "error" => true}
      html = preview_html(task_list("t1"), entry)

      assert html =~ "Live task preview unavailable"
      refute html =~ "Loading live tasks"
    end

    test "a query block with no entry yet shows the honest loading note" do
      html = preview_html(task_list("t1"), nil)
      assert html =~ "Loading live tasks"
    end

    test "an author-pinned literal snapshot renders directly from its own rows" do
      pinned = %{
        "id" => "t1",
        "type" => "task-list",
        "snapshot" => [%{"title" => "Pinned row", "status" => "done"}]
      }

      html = preview_html(pinned, nil)
      assert html =~ "Pinned row"
      refute html =~ "Loading live tasks"
    end

    test "a matchless task-detail preview shows an explicit empty note, not a blank strip" do
      block = %{"id" => "d1", "type" => "task-detail", "query" => %{"nope" => 1}}
      entry = %{"block_id" => "d1", "type" => "task-detail", "task" => %{}}

      html = preview_html(block, entry)
      assert html =~ "No matching tasks."
    end

    test "flag OFF (explicit opt-out): the shipped per-block list stays byte-free of any preview markup" do
      # The canvas is the default now (D7/D9), so OFF is an EXPLICIT opt-out —
      # `delete_env` would leave the canvas ON. Pin the opt-out value.
      System.put_env("BARKPARK_PAPER_CANVAS", "0")

      html = editor_html([task_list("t1")], %{"t1" => %{"block_id" => "t1", "snapshot" => []}})
      refute html =~ "paper-task-preview"
    end

    test "pdd-t8: a STATIC (non-task) fleet block paints the reader's producer directly" do
      # `cards` carries no query + no preview entry — the widget renders it straight
      # through Render.render_block/2 (rule 3: one producer, byte for byte), not just
      # the raw editable fields.
      cards = %{
        "id" => "c1",
        "type" => "cards",
        "items" => [%{"title" => "Kinsta", "text" => "honest states"}]
      }

      html = preview_html(cards, nil)

      assert html =~ ~s(data-test-id="paper-task-preview"),
             "the fleet block gets a preview widget"

      assert html =~ "Kinsta"

      assert html =~ Render.render_block(cards, %{style: :article}),
             "the widget emits the EXACT reader bytes for the static fleet block"
    end

    test "pdd-t8: an EMPTY static fleet block gets a component-vocabulary empty note" do
      # cards with no items renders "" through the reader producer — the widget must
      # say so in the block's OWN vocabulary, not the task copy ("No matching
      # tasks." on an empty cards block would be a lie).
      html = preview_html(%{"id" => "c2", "type" => "cards", "items" => []}, nil)

      assert html =~ "Nothing to show yet."
      refute html =~ "No matching tasks."
    end

    test "pdd-t8: a stray query key on a STATIC fleet block never wedges it in loading" do
      # Only the query-carrying task types ever get preview entries, so a static
      # block carrying a stray "query" would previously spin forever — it must
      # render directly instead.
      cards = %{
        "id" => "c3",
        "type" => "cards",
        "query" => %{"status" => "ready"},
        "items" => [%{"title" => "Painted", "text" => "not loading"}]
      }

      html = preview_html(cards, nil)

      assert html =~ "Painted"
      refute html =~ "Loading live tasks…"
    end
  end

  describe "paper_canvas_enabled?/0 (default TRUE — the D7/D9 cutover)" do
    setup do
      prev = System.get_env("BARKPARK_PAPER_CANVAS")

      on_exit(fn ->
        case prev do
          nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
          v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
        end
      end)

      :ok
    end

    test "unset → true (the shipped default — the canvas is the mainline editor)" do
      System.delete_env("BARKPARK_PAPER_CANVAS")
      assert PaperCanvas.paper_canvas_enabled?()
    end

    test "the two explicit opt-out strings '0' / 'false' (case-insensitive, trimmed) → false" do
      for v <- ["0", "false", "FALSE", "False", " false ", "  0 "] do
        System.put_env("BARKPARK_PAPER_CANVAS", v)
        refute PaperCanvas.paper_canvas_enabled?(), "expected #{inspect(v)} → false (opt-out)"
      end
    end

    test "'1' / 'true' (case-insensitive, trimmed) → true" do
      for v <- ["1", "true", "TRUE", "True", " true ", "  1 "] do
        System.put_env("BARKPARK_PAPER_CANVAS", v)
        assert PaperCanvas.paper_canvas_enabled?(), "expected #{inspect(v)} → true"
      end
    end

    test "empty / junk / any non-opt-out value → true (fails toward the mainline)" do
      for v <- ["", "  ", "off", "no", "false-ish", "2", "yes", "disabled"] do
        System.put_env("BARKPARK_PAPER_CANVAS", v)

        assert PaperCanvas.paper_canvas_enabled?(),
               "expected #{inspect(v)} → true (not an opt-out)"
      end
    end
  end

  # ── t6: WordPress-style metadata sidebar (doctrine Rule 4/5) ─────────────────

  describe "sidebar_slug_valid?/1 + slug_feedback/1 (instant format validation)" do
    test "valid WordPress-style slugs pass" do
      for s <- ["post", "my-post", "a1", "hello-world-2026", "x-y-z"] do
        assert PaperCanvas.sidebar_slug_valid?(s), "expected #{inspect(s)} valid"
        assert {:ok, "Looks good"} = PaperCanvas.slug_feedback(s)
      end
    end

    test "empty slug is a WARN, not a hard error (nothing typed yet)" do
      refute PaperCanvas.sidebar_slug_valid?("")
      assert {:warn, msg} = PaperCanvas.slug_feedback("")
      assert msg =~ "required"
    end

    test "capitals / spaces are DANGER with a specific message" do
      refute PaperCanvas.sidebar_slug_valid?("My-Post")
      assert {:danger, cap} = PaperCanvas.slug_feedback("My-Post")
      assert cap =~ "Lowercase"

      refute PaperCanvas.sidebar_slug_valid?("my post")
      assert {:danger, sp} = PaperCanvas.slug_feedback("my post")
      assert sp =~ "spaces"
    end

    test "leading / trailing / doubled hyphens are a recoverable WARN" do
      for s <- ["-post", "post-", "my--post"] do
        refute PaperCanvas.sidebar_slug_valid?(s)
        feedback = PaperCanvas.slug_feedback(s)

        assert match?({:warn, _}, feedback),
               "expected #{inspect(s)} warn, got #{inspect(feedback)}"

        {:warn, msg} = feedback
        assert msg =~ "hyphen"
      end
    end

    test "other invalid characters are DANGER; non-binary input never raises" do
      assert {:danger, _} = PaperCanvas.slug_feedback("post!")
      assert {:danger, _} = PaperCanvas.slug_feedback(nil)
      refute PaperCanvas.sidebar_slug_valid?(nil)
    end
  end

  describe "sidebar_meta_op/2 (a DOC-FIELD op, structurally NOT a block op)" do
    test "returns a {:doc_field, field, value} tuple — never the block-op map shape" do
      op = PaperCanvas.sidebar_meta_op("slug", "my-post")
      assert op == {:doc_field, "slug", "my-post"}

      # A body block op is a MAP carrying an "op" key (patch-block / remove-block /
      # insert-after / …). A sidebar op is a tuple with none of those keys — so it
      # can never be mistaken for, or applied as, a block op.
      refute is_map(op)
      assert elem(op, 0) == :doc_field
    end
  end

  describe "sidebar_section_open?/2 + toggle_section/2 (collapse persists in a MapSet)" do
    test "sections default to OPEN when the collapsed set is empty / absent" do
      assert PaperCanvas.sidebar_section_open?(MapSet.new(), "publish")
      assert PaperCanvas.sidebar_section_open?(nil, "slug")
    end

    test "toggling a section collapses it, toggling again re-opens it" do
      c0 = MapSet.new()
      c1 = PaperCanvas.toggle_section(c0, "labels")
      refute PaperCanvas.sidebar_section_open?(c1, "labels")
      # other sections are unaffected
      assert PaperCanvas.sidebar_section_open?(c1, "publish")

      c2 = PaperCanvas.toggle_section(c1, "labels")
      assert PaperCanvas.sidebar_section_open?(c2, "labels")
    end

    test "toggle_section seeds a set from nil (first toggle collapses)" do
      c1 = PaperCanvas.toggle_section(nil, "context")
      assert MapSet.member?(c1, "context")
    end

    test "the five fixed sections are exactly publish/slug/context/labels/relations" do
      assert PaperCanvas.sidebar_sections() == ~w(publish slug context labels relations)
    end
  end

  describe "paper_labels/1 + paper_relations/1 + visibility_label/1 (only non-article metadata)" do
    test "labels come from content tags; blanks dropped; missing ⇒ []" do
      paper = %{content: %{"tags" => ["design", "  ", "obsidian", 42]}}
      assert PaperCanvas.paper_labels(paper) == ["design", "obsidian"]
      assert PaperCanvas.paper_labels(%{content: %{}}) == []
      assert PaperCanvas.paper_labels(nil) == []
    end

    test "weighted tags render as their NAMES — the Labels sidebar is never blank for post-wall papers (D18)" do
      weighted = %{
        content: Barkpark.LabelFixtures.named_weighted_labels(["design-w", "obsidian-w"])
      }

      assert PaperCanvas.paper_labels(weighted) == ["design-w", "obsidian-w"]
    end

    test "mixed shapes coexist: flat strings + weighted entries; junk maps and blanks dropped" do
      [weighted_entry] = Barkpark.LabelFixtures.named_weighted_labels(["weighted-tag"])["tags"]

      paper = %{
        content: %{"tags" => ["flat-tag", weighted_entry, %{"nota" => "tag"}, "", 42]}
      }

      assert PaperCanvas.paper_labels(paper) == ["flat-tag", "weighted-tag"]
    end

    test "relations are field-reference blocks with a non-blank value" do
      blocks = [
        %{"id" => "r1", "type" => "field-reference", "value" => "author-1", "label" => "Author"},
        %{"id" => "r2", "type" => "field-reference", "value" => ""},
        %{"id" => "p1", "type" => "paragraph"}
      ]

      assert PaperCanvas.paper_relations(blocks) == [
               %{id: "author-1", label: "Author", ref_type: nil}
             ]

      assert PaperCanvas.paper_relations([]) == []
      assert PaperCanvas.paper_relations(nil) == []
    end

    test "visibility is derived from publish status (papers publish to /papers/:slug)" do
      assert PaperCanvas.visibility_label("published") == "Public"
      # "Draft" only — never "not public": the public reader fetches by exact
      # doc_id with NO status filter, so a stronger claim could lie.
      assert PaperCanvas.visibility_label("draft") == "Draft"
      refute PaperCanvas.visibility_label("draft") =~ "public"
    end
  end

  describe "paper_metadata_sidebar/1 render (the calm right document panel)" do
    defp draft_paper(overrides \\ %{}) do
      Map.merge(
        %{
          doc_id: "my-post",
          title: "My Post",
          status: "draft",
          content: %{"blocks" => [], "tags" => ["design"]}
        },
        overrides
      )
    end

    defp render_sidebar(assigns) do
      base = %{
        paper_doc: draft_paper(),
        dataset: "production",
        panel_open: true,
        collapsed: MapSet.new(),
        slug_draft: nil,
        slug_feedback: nil,
        workspace_label: nil
      }

      render_component(&Components.paper_metadata_sidebar/1, Map.merge(base, assigns))
    end

    test "renders all five sections, each with a tabbable aria-expanded toggle" do
      html = render_sidebar(%{})
      assert html =~ ~s(data-test-id="paper-metadata-sidebar")

      for key <- ~w(publish slug context labels relations) do
        assert html =~ ~s(data-test-id="sidebar-section-#{key}"),
               "expected the #{key} section to render"

        assert html =~ ~s(data-test-id="sidebar-section-toggle-#{key}")
      end

      # section toggles are real <button>s (Enter/Space toggle) carrying aria-expanded
      assert html =~ ~s(aria-expanded="true")
      assert html =~ "phx-value-section="
    end

    test "a DRAFT paper shows draft status + Draft visibility — and NO publish action" do
      html = render_sidebar(%{})
      assert html =~ ~s(data-test-id="sidebar-status")
      assert html =~ "draft"
      assert html =~ "Draft"
    end

    test "a PUBLISHED paper shows Public visibility" do
      html = render_sidebar(%{paper_doc: draft_paper(%{status: "published"})})
      assert html =~ "published"
      assert html =~ "Public"
    end

    test "the Publish section offers NO publish/unpublish action (papers publish in place)" do
      # Papers are single-row, published-in-place (`upsert_paper` always writes
      # doc_id = slug, status "published"); the doc-level publish/unpublish
      # events assume the drafts-twin model — publish would always fail (no
      # drafts.<slug> row) and unpublish would DELETE the published row and
      # strand a twin no paper read-path resolves. Until a paper-aware
      # lifecycle exists, the section is read-only state — a broken or
      # destructive button here fails the honest-affordance bar.
      for status <- ["draft", "published"] do
        html = render_sidebar(%{paper_doc: draft_paper(%{status: status})})
        refute html =~ ~s(data-test-id="sidebar-publish")
        refute html =~ ~s(data-test-id="sidebar-unpublish")
        refute html =~ ~s(phx-click="publish")
        refute html =~ ~s(phx-click="unpublish")
      end
    end

    test "the slug section shows the current slug + a live format verdict with a tone" do
      html = render_sidebar(%{})
      assert html =~ ~s(data-test-id="sidebar-slug-input")
      assert html =~ ~s(value="my-post")
      assert html =~ ~s(phx-change="sidebar-slug-change")
      # a valid slug ⇒ ok tone
      assert html =~ ~s(data-tone="ok")
      assert html =~ "Looks good"
    end

    test "an invalid slug_draft surfaces the danger tone + aria-invalid" do
      html =
        render_sidebar(%{
          slug_draft: "My Post",
          slug_feedback: PaperCanvas.slug_feedback("My Post")
        })

      assert html =~ ~s(data-tone="danger")
      assert html =~ ~s(aria-invalid="true")
    end

    test "Context is read-only dataset + workspace; the slug NEVER duplicates the title" do
      html = render_sidebar(%{workspace_label: "Acme"})
      assert html =~ ~s(data-test-id="sidebar-dataset")
      assert html =~ "production"
      assert html =~ "Acme"
      # doctrine: the title stays a locked body block — it is not surfaced here.
      refute html =~ ~s(name="title")
    end

    test "labels + relations render honest empty states when absent" do
      html = render_sidebar(%{paper_doc: draft_paper(%{content: %{"blocks" => []}})})
      assert html =~ ~s(data-test-id="sidebar-labels-empty")
      assert html =~ ~s(data-test-id="sidebar-relations-empty")
    end

    test "labels + relations render their content when present" do
      paper =
        draft_paper(%{
          content: %{
            "tags" => ["design", "obsidian"],
            "blocks" => [
              %{
                "id" => "r1",
                "type" => "field-reference",
                "value" => "author-1",
                "label" => "Author"
              }
            ]
          }
        })

      html = render_sidebar(%{paper_doc: paper})
      assert html =~ ~s(data-test-id="sidebar-labels")
      assert html =~ "design"
      assert html =~ "obsidian"
      assert html =~ ~s(data-test-id="sidebar-relations")
      assert html =~ "Author"
      assert html =~ "author-1"
    end

    test "a COLLAPSED section hides its body but keeps the toggle (chrome, no reflow)" do
      html = render_sidebar(%{collapsed: MapSet.new(["labels"])})
      # toggle still there, now aria-expanded=false; the body id is gone
      assert html =~ ~s(data-test-id="sidebar-section-toggle-labels")
      assert html =~ ~s(aria-expanded="false")
      refute html =~ ~s(id="bp-doc-sec-body-labels")
    end

    test "a COLLAPSED panel hides the section body entirely (no overlay, no mode)" do
      html = render_sidebar(%{panel_open: false})
      assert html =~ "is-collapsed"
      refute html =~ ~s(id="bp-doc-sidebar-body")
      refute html =~ ~s(data-test-id="sidebar-section-publish")
    end

    # spd-b29f — the PANEL control's own announcement, isolated from the five
    # SECTION toggles. The pre-existing loose `assert html =~ aria-expanded="true"`
    # above is satisfied by any section, which is exactly how the painted-closed
    # lie survived a wave; these read the panel button's OWN attributes out of the
    # markup so a regression cannot hide behind a neighbour.
    defp panel_toggle(html) do
      # spd-b39: ONE control, TWO test ids. At Tier 3 (narrow/phone + user
      # opened) it is the destination's dismissal and identifies itself as
      # `sidebar-dismiss` so the deployed probe can find the exit by name;
      # everywhere else it stays `sidebar-toggle-panel`. This helper is about
      # the control's ANNOUNCEMENT, which both spellings must get right, so it
      # locates whichever id this bucket rendered rather than pinning one.
      marker =
        if String.contains?(html, ~s(data-test-id="sidebar-dismiss")),
          do: ~s(data-test-id="sidebar-dismiss"),
          else: ~s(data-test-id="sidebar-toggle-panel")

      [head, tail] = String.split(html, marker, parts: 2)
      # attributes sit BEFORE the test-id on the opening tag, the glyph after it
      (head |> String.split("<button") |> List.last()) <> String.slice(tail, 0, 300)
    end

    # `<.icon>` inlines the SVG, so the glyph is only identifiable by its path
    # data (Icons.icons/0: chevron-down "m6 9 6 6 6-6", chevron-right "m9 18 6-6-6-6").
    defp chevron(control) do
      cond do
        control =~ ~s(d="m6 9 6 6 6-6") -> "chevron-down"
        control =~ ~s(d="m9 18 6-6-6-6") -> "chevron-right"
        # spd-b39/D167 — the Tier-3 glyph. At narrow/phone with the panel
        # summoned, the control is the ONLY exit from a full-screen
        # destination, so it points the way the action goes.
        control =~ ~s(d="m12 19-7-7 7-7") -> "arrow-left"
        true -> "no-chevron"
      end
    end

    test "below WIDE, an open-but-never-asked-for panel announces itself CLOSED (spd-b29f)" do
      # spd-b29's cascade paints exactly this state as the 41px collapsed strip
      # (D102), so a control saying aria-expanded="true" here is the a11y lie
      # #4633 landed to fix — two geometrically identical states must not
      # announce opposite things.
      for bucket <- ~w(standard narrow phone) do
        control =
          panel_toggle(
            render_sidebar(%{panel_open: true, user_opened: false, width_bucket: bucket})
          )

        assert control =~ ~s(aria-expanded="false"),
               "#{bucket}: painted-closed panel must not announce itself expanded"

        assert control =~ "Expand document panel",
               "#{bucket}: title must offer the EXPAND direction over a closed strip"

        assert chevron(control) == "chevron-right",
               "#{bucket}: chevron must point the expand direction over a closed strip"
      end
    end

    test "an EXPLICIT user open announces itself OPEN at every bucket (spd-b29f)" do
      # data-user-opened makes the b29 rule stop matching, so the panel really is
      # visible — the announcement must follow the pixels back. That half is
      # bucket-INDEPENDENT and stays so.
      for bucket <- ~w(wide standard narrow phone) do
        control =
          panel_toggle(
            render_sidebar(%{panel_open: true, user_opened: true, width_bucket: bucket})
          )

        assert control =~ ~s(aria-expanded="true"),
               "#{bucket}: user-opened panel is genuinely open"
      end
    end

    # spd-b39/D167 — the LABEL and GLYPH, unlike the announcement above, are
    # tier-dependent, and deliberately so. At wide and standard the panel is
    # chrome beside the prose and the action collapses it downward. At narrow
    # and phone a summoned panel IS the screen (wave-10 paints it `inset:0`
    # over an opaque surface), so the same control is a way BACK — pointing it
    # down would describe a motion the click does not perform.
    test "the label and glyph follow the tier: collapse above, RETURN at Tier 3 (spd-b39)" do
      for bucket <- ~w(wide standard) do
        control =
          panel_toggle(
            render_sidebar(%{panel_open: true, user_opened: true, width_bucket: bucket})
          )

        assert control =~ "Collapse document panel",
               "#{bucket}: a docked panel collapses; it is not a destination to leave"

        assert chevron(control) == "chevron-down"
      end

      for bucket <- ~w(narrow phone) do
        control =
          panel_toggle(
            render_sidebar(%{panel_open: true, user_opened: true, width_bucket: bucket})
          )

        assert chevron(control) == "arrow-left",
               "#{bucket}: the exit from a full-screen destination must point back"

        assert control =~ "Back to",
               "#{bucket}: the control must name where pressing it goes"

        refute control =~ "Collapse document panel",
               "#{bucket}: 'Collapse' describes chrome, not a full-screen return"
      end
    end

    test "a server-CLOSED panel announces closed regardless of bucket (spd-b29f)" do
      for bucket <- ~w(wide standard narrow phone) do
        control = panel_toggle(render_sidebar(%{panel_open: false, width_bucket: bucket}))

        assert control =~ ~s(aria-expanded="false"),
               "#{bucket}: collapsed panel is never expanded"
      end
    end

    test "FIRST BYTE IS UNMOVED — the wide default renders byte-identically (D12/D91)" do
      # The server cannot know the bucket at first paint; mount seeds "wide", so
      # an un-threaded call site and an explicitly-wide one must be the same
      # bytes, and the wide render must still announce OPEN. If this ever fails,
      # the change has started painting before the client is known — too far.
      unthreaded = render_sidebar(%{panel_open: true, user_opened: false})
      seeded = render_sidebar(%{panel_open: true, user_opened: false, width_bucket: "wide"})

      assert unthreaded == seeded,
             "threading width_bucket must not change what renders at first byte"

      control = panel_toggle(unthreaded)
      assert control =~ ~s(aria-expanded="true")
      assert control =~ "Collapse document panel"
      assert chevron(control) == "chevron-down"
    end

    test "the panel body/title still key off panel_open ALONE — only the announcement moved" do
      # DOM PRESENCE is deliberately untouched by spd-b29f: below wide the body
      # is still in the document (CSS hides it), because gating it on the bucket
      # would change what paints at first byte and re-open D12.
      html = render_sidebar(%{panel_open: true, user_opened: false, width_bucket: "narrow"})
      assert html =~ ~s(id="bp-doc-sidebar-body")
      assert html =~ ~s(class="bp-doc-sidebar__title")
      assert html =~ "bp-doc-sidebar is-open"
      assert html =~ ~s(data-test-id="sidebar-section-publish")
    end

    # REVIEW FIX (spd-b29f review). The announcement lives in components.ex
    # (`visually_open?`) and the ACTION lives in
    # `Handlers.Paper.sidebar_toggle_panel/1` (`painted_closed?`). They are
    # exact negations of one another today and nothing said so — the builder
    # named this coupling as the most likely way the slice rots, and a comment
    # is not a guard. The invariant is the one a reader can actually check with
    # their eyes: a button that says "Expand" must EXPAND when it is pressed,
    # and a button that says "Collapse" must COLLAPSE. Pinning that end to end
    # catches a drift in EITHER file, from either side.
    test "the control's announcement and its ACTION agree at every bucket (spd-b29f review)" do
      for bucket <- ~w(wide standard narrow phone),
          open? <- [true, false],
          asked? <- [true, false] do
        before_control =
          panel_toggle(
            render_sidebar(%{panel_open: open?, user_opened: asked?, width_bucket: bucket})
          )

        announced_open? = before_control =~ ~s(aria-expanded="true")

        socket = %Phoenix.LiveView.Socket{
          assigns: %{
            __changed__: %{},
            sidebar_open: open?,
            sidebar_user_opened: asked?,
            width_bucket: bucket
          }
        }

        {:noreply, after_socket} = PaperHandler.sidebar_toggle_panel(socket)

        after_control =
          panel_toggle(
            render_sidebar(%{
              panel_open: after_socket.assigns.sidebar_open,
              user_opened: after_socket.assigns.sidebar_user_opened,
              width_bucket: bucket
            })
          )

        assert after_control =~ ~s(aria-expanded="true") == not announced_open?,
               """
               THE CONTROL LIES ABOUT WHAT PRESSING IT DOES.

               bucket=#{bucket} panel_open=#{open?} user_opened=#{asked?}:
               the button announced #{if announced_open?, do: "OPEN", else: "CLOSED"},
               and one press left it announcing the SAME thing.

               `visually_open?` in components.ex and `painted_closed?` in
               Handlers.Paper.sidebar_toggle_panel/1 are the same predicate
               written twice, in two files, in opposite polarity. They have
               drifted. Below `wide` an open-but-never-asked panel is PAINTED
               closed, so a press must mean OPEN — not "toggle the assign" —
               and the announcement must say CLOSED beforehand. Whichever of
               the two moved, move the other with it.
               """
      end
    end
  end

  describe "a sidebar edit never touches body blocks (doctrine Rule 4)" do
    # A minimal socket carrying the sidebar assigns + a paper with a KNOWN block
    # list. The pure-assign handlers never call Content / Shared.paper_op, so no
    # DB sandbox is involved — and the block list must be byte-identical after.
    defp sidebar_socket do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          sidebar_open: true,
          sidebar_collapsed: MapSet.new(),
          sidebar_slug_draft: "my-post",
          sidebar_slug_feedback: {:ok, "Looks good"},
          paper_block_mode: true,
          paper_edit_mode: true,
          paper_doc: %{
            doc_id: "my-post",
            status: "draft",
            content: %{"blocks" => [%{"id" => "b1", "type" => "paragraph"}]}
          }
        }
      }
    end

    test "a slug change emits NO block op: it only re-assigns the slug draft + verdict" do
      before = sidebar_socket()
      before_blocks = before.assigns.paper_doc.content["blocks"]

      {:noreply, after_socket} =
        PaperHandler.sidebar_slug_change(%{"value" => "My New Slug"}, before)

      # the live verdict updated…
      assert after_socket.assigns.sidebar_slug_draft == "My New Slug"
      assert {:danger, _} = after_socket.assigns.sidebar_slug_feedback

      # …and the body blocks are IDENTICAL — the edit never reached the block path.
      assert after_socket.assigns.paper_doc.content["blocks"] == before_blocks
      # no stream mutation was staged for :paper_blocks
      refute Map.has_key?(after_socket.assigns.__changed__, :paper_blocks)
    end

    test "toggling a section / the panel is a pure assign — blocks untouched" do
      s0 = sidebar_socket()

      {:noreply, s1} = PaperHandler.sidebar_toggle_section(%{"section" => "labels"}, s0)
      assert MapSet.member?(s1.assigns.sidebar_collapsed, "labels")
      assert s1.assigns.paper_doc.content["blocks"] == s0.assigns.paper_doc.content["blocks"]

      {:noreply, s2} = PaperHandler.sidebar_toggle_panel(s1)
      refute s2.assigns.sidebar_open
      assert s2.assigns.paper_doc.content["blocks"] == s0.assigns.paper_doc.content["blocks"]
    end

    test "a malformed slug/section payload is a safe no-op" do
      s0 = sidebar_socket()
      assert {:noreply, ^s0} = PaperHandler.sidebar_slug_change(%{}, s0)
      assert {:noreply, ^s0} = PaperHandler.sidebar_toggle_section(%{}, s0)
    end
  end

  # ── pdd-t20c: constraint vocabulary — ghost slots + the data-constraints stamp ──

  describe "ghost_slots/1 (the pure model, gated on a doctrine paper + save-safety)" do
    alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

    defp locked_title(id \\ "tpl-title"),
      do: %{"id" => id, "type" => "heading", "level" => 1, "role" => "title", "locked" => true}

    defp locked_featured(id \\ "tpl-featured"),
      do: %{"id" => id, "type" => "image", "role" => "featured", "locked" => true}

    test "a doctrine paper (locked title, no optionals) offers BOTH ghosts, ordered ingress→featured" do
      blocks = [locked_title(), para("body")]
      slots = PaperEditor.ghost_slots(blocks)

      assert Enum.map(slots, & &1.kind) == ["ingress", "featured"]
      assert Enum.find(slots, &(&1.kind == "featured")).locked == true
      assert Enum.find(slots, &(&1.kind == "ingress")).locked == false
      assert Enum.all?(slots, &(&1.after == "title"))
    end

    test "a present optional drops its ghost (featured present → only ingress remains)" do
      # featured sits at block 1 (after the title); ingress is still absent AND
      # save-safe? NO — inserting ingress after the title would displace the LOCKED
      # featured, so the ghost is withheld (never a save error, rule 5).
      blocks = [locked_title(), locked_featured()]
      assert PaperEditor.ghost_slots(blocks) == []
    end

    test "a NON-doctrine paper (no locked blocks) offers no ghosts (additive, D3)" do
      assert PaperEditor.ghost_slots([para("p1"), para("p2")]) == []
    end

    test "the ingress ghost IS offered when its insert is save-safe (title then an unlocked block)" do
      # title + an unlocked paragraph: inserting ingress after the title displaces
      # only the unlocked paragraph → safe → the ingress ghost is offered.
      blocks = [locked_title(), para("body")]
      assert Enum.any?(PaperEditor.ghost_slots(blocks), &(&1.kind == "ingress"))
    end
  end

  describe "the flag-ON canvas stamps constraints + paints the ghost slots (doctrine paper)" do
    alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

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

    defp doctrine_html(blocks) do
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "doctrine-p",
        blocks: blocks,
        canvas_eligible: true,
        task_previews: %{}
      )
    end

    test "the canvas run carries data-canvas-constraints (the JSON declarations) for a locked-carrying doc" do
      html = doctrine_html([locked_title(), para("body")])

      assert html =~ ~s(data-canvas-constraints=)
      # the declaration kinds ride the stamp
      assert html =~ "featured"
      assert html =~ "ingress"
      assert html =~ ~s(&quot;presence&quot;)
    end

    test "a NON-doctrine paper does NOT stamp constraints (additive — the attr renders empty)" do
      html = doctrine_html([para("p1"), para("p2")])

      refute html =~ ~s(data-canvas-constraints=&quot;[)
      refute html =~ ~s(data-test-id="paper-ghost-slots")
    end

    test "the absent optionals paint as calm ghost affordances after the title run" do
      html = doctrine_html([locked_title(), para("body")])

      assert html =~ ~s(data-test-id="paper-ghost-slots")
      assert html =~ ~s(data-test-id="paper-ghost-featured")
      assert html =~ ~s(data-test-id="paper-ghost-ingress")
      # each ghost is a real button wired to the materialize event, keyed by kind,
      # carrying the anchor (the locked title id) — a click can only INSERT-AFTER.
      assert html =~ ~s(phx-click="paper-materialize-slot")
      assert html =~ ~s(phx-value-kind="featured")
      assert html =~ ~s(phx-value-after="tpl-title")
      # accessible name, never a bare glyph
      assert html =~ "Add the optional featured image"
    end

    test "a paper whose optionals are already present shows NO ghosts (no empty husk, no dup slot)" do
      full = [
        locked_title(),
        %{"id" => "ing", "type" => "paragraph", "role" => "ingress", "content" => []},
        locked_featured()
      ]

      html = doctrine_html(full)
      refute html =~ ~s(data-test-id="paper-ghost-slots")
    end
  end

  describe "paper_materialize_slot/2 (the ghost → real block op)" do
    alias BarkparkWeb.Studio.StudioLive.Handlers.Paper, as: P

    defp materialize_socket(blocks) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          paper_doc: %{doc_id: "doctrine-p", content: %{"blocks" => blocks}},
          paper_rev: 0,
          dataset: "production"
        }
      }
    end

    test "an unknown slot kind replies unsaved without changing the document" do
      s0 = materialize_socket([%{"id" => "t", "role" => "title", "locked" => true}])

      assert {:reply, %{saved: false, request_id: nil} = receipt, socket} =
               P.paper_materialize_slot(%{"kind" => "nope", "after" => "t"}, s0)

      assert socket.assigns.paper_doc == s0.assigns.paper_doc
      assert socket.assigns.paper_rev == s0.assigns.paper_rev
      assert socket.assigns.save_status == "Save failed"
      assert socket.assigns.last_paper_save_result == receipt
      refute socket.assigns.last_paper_save_ok?
    end

    test "a malformed payload is a safe no-op" do
      s0 = materialize_socket([])

      assert {:reply, %{saved: false, request_id: nil} = receipt, socket} =
               P.paper_materialize_slot(%{}, s0)

      assert socket.assigns.paper_doc == s0.assigns.paper_doc
      assert socket.assigns.paper_rev == s0.assigns.paper_rev
      assert socket.assigns.save_status == "Save failed"
      assert socket.assigns.last_paper_save_result == receipt
      refute socket.assigns.last_paper_save_ok?
    end
  end

  describe "view↔reader button parity (editable-action)" do
    # The reader emits the CTA anchor with .bp-button / .bp-button--primary, styled by
    # paper-surface.css (.bp-paper-surface-scoped). The canvas action node-view renders a
    # LIVE PREVIEW anchor carrying the SAME classes, styled by the editor mirrors under
    # .bp-canvas-action so they reach the editor sink (.bp-paper-editor-body). The
    # paper-editor-mirror-check tripwire only checks class-token PRESENCE, NOT declaration
    # byte-equality, and the reader .bp-button tokens are NOT .bp-canvas-* — so this is the
    # gate that closes the ungoverned reader↔editor .bp-button parity: it asserts the
    # DECLARATIONS match the reader byte-for-byte in BOTH editor sinks.
    @reader_css Path.expand("../../../../assets/paper-surface/paper-surface.css", __DIR__)
    @bundle_css Path.expand("../../../../assets/paper-editor/src/styles.css", __DIR__)
    # edit-on-the-link: the Studio editor's `.bp-canvas-*` rules moved out of
    # root.html.heex's inline <style> into the shell stylesheet the layout now
    # links (and the public reader links too). Same sink, new file.
    @heex_css Path.expand(
                "../../../../priv/static/assets/bp-paper-editor-shell.css",
                __DIR__
              )

    test ".bp-button + .bp-button--primary match the reader in BOTH editor sinks" do
      reader = File.read!(@reader_css)
      reader_btn = button_decls(reader, ".bp-paper-surface .bp-button")
      reader_primary = button_decls(reader, ".bp-paper-surface .bp-button--primary")

      # distrust-vacuous-green: the reader rules are real + non-empty. The frame
      # reads its weight from the rule ladder (space.rule → --bp-rule-hairline);
      # it was a 2px literal until the heavy-rule census ruled that the
      # structural weight belongs to a section boundary alone, and a button
      # outline is chrome.
      assert reader_btn =~ "border: var(--bp-rule-hairline) solid var(--paper-accent)"
      assert reader_primary =~ "background: var(--paper-accent)"

      for {sink, path} <- [{"styles.css", @bundle_css}, {"bp-paper-editor-shell.css", @heex_css}] do
        css = File.read!(path)

        assert button_decls(css, ".bp-canvas-action .bp-button") == reader_btn,
               "#{sink}: .bp-canvas-action .bp-button diverged from the reader .bp-button"

        assert button_decls(css, ".bp-canvas-action .bp-button--primary") == reader_primary,
               "#{sink}: .bp-canvas-action .bp-button--primary diverged from the reader --primary"
      end
    end
  end
end
