defmodule BarkparkWeb.Studio.StudioLive.PaperCanvasTest do
  @moduledoc """
  Phase-4 S2 — unit tests for the PURE Studio-side canvas seam:

    * `partition_runs/1` — partition a block list into maximal contiguous prose
      runs (`{:run, blocks}`) and non-prose boundaries (`{:block, block}`).
    * `paper_canvas_enabled?/0` — the BARKPARK_PAPER_CANVAS flag, default FALSE.
    * `run_id/1` — the stable run id (first block's id).

  No LiveView, no DB — these are the cheap, exhaustive proofs of the partition
  logic the render branch depends on.
  """
  use ExUnit.Case, async: false

  alias Barkpark.PortableDoc.TaskResolver
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

  defp para(id), do: %{"id" => id, "type" => "paragraph", "content" => []}
  defp heading(id), do: %{"id" => id, "type" => "heading", "text" => "H", "level" => 2}
  defp list(id), do: %{"id" => id, "type" => "list", "ordered" => false, "items" => []}
  defp callout(id), do: %{"id" => id, "type" => "callout", "tone" => "info"}
  defp divider(id), do: %{"id" => id, "type" => "divider"}
  # RUN-SPLITTER TAIL (part 1): the 2 PICKER field-* types (field-image /
  # field-reference) are now canvas-eligible too (their WCs are client-side — no
  # LiveView dependency — so they mount inside the canvas as control-atoms). The ONLY
  # remaining run boundaries are the NESTED-STRUCTURE fields (composite / arrayOf /
  # codelist / localizedText / section), a separate increment. `boundary/1` therefore
  # produces a `composite` (a still-splitting boundary); `boundary2/1` produces an
  # `arrayOf` (a SECOND distinct boundary, used where two adjacent boundaries are
  # needed). `picker/1` and `picker_ref/1` produce the now-canvas-eligible picker fields
  # used to prove they RIDE a run. `native_field/1` produces a field-string.
  defp boundary(id), do: %{"id" => id, "type" => "composite", "fields" => [], "value" => %{}}
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

  # t9: a task-list block is NOT canvas-eligible (it renders as a boundary
  # widget), so it partitions to a `{:block, raw}` — and the raw block the editor
  # mounts (and later saves) still carries its live `query`, never a snapshot.
  defp task_list(id), do: %{"id" => id, "type" => "task-list", "query" => %{"parent_id" => "epic"}}

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
      # native field-* types, the 2 pickers, sheet, embed) — so the ONLY still-splitting
      # boundaries are the nested-structure fields (composite / arrayOf / codelist /
      # localizedText / section).
      for boundary <- [
            %{"id" => "b", "type" => "composite", "fields" => [], "value" => %{}},
            %{"id" => "b", "type" => "arrayOf", "of" => %{}, "value" => []},
            %{"id" => "b", "type" => "codelist", "value" => ""},
            %{"id" => "b", "type" => "localizedText", "value" => %{}},
            %{"id" => "b", "type" => "section"}
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

      # Still boundaries — only the NESTED-STRUCTURE fields stay run boundaries.
      refute PaperCanvas.canvas?(boundary("cmp"))
      refute PaperCanvas.canvas?(boundary2("arr"))
      refute PaperCanvas.canvas?(%{"id" => "x"})
    end
  end

  describe "run_id/1 (Bug #1a: keyed by ORDINAL, not first-block id)" do
    test "is \"run-\" <> ordinal — a STABLE string id, NOT the first block's id" do
      # Run identity is the run's ORDINAL in partition_runs output, not its mutable
      # first-block id. (Previously run_id([first | _]) returned first["id"], which
      # changed when a run's leading block was deleted — the bug.)
      assert PaperCanvas.run_id(0) == "run-0"
      assert PaperCanvas.run_id(1) == "run-1"
      assert PaperCanvas.run_id(7) == "run-7"
    end

    test "the id is a non-empty STRING so the hook's `!run.run_id` guard never drops run 0" do
      # The inbound hook guards `if (!run.run_id) return;`. A bare integer 0 would be
      # falsy → the FIRST run's echo silently dropped. The "run-" prefix makes every
      # ordinal id truthy.
      assert PaperCanvas.run_id(0) == "run-0"
      assert is_binary(PaperCanvas.run_id(0))
      refute PaperCanvas.run_id(0) == ""
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
      # wrapper id (run_id(ordinal)) is unchanged → no remount, echo still matches.
      before = PaperCanvas.partition_runs([para("p1"), para("p2"), para("p3")])
      after_del = PaperCanvas.partition_runs([para("p2"), para("p3")])

      [{:run, _, ord_before}] = PaperCanvas.with_run_ordinals(before)
      [{:run, _, ord_after}] = PaperCanvas.with_run_ordinals(after_del)

      assert ord_before == 0
      assert ord_after == 0
      assert PaperCanvas.run_id(ord_before) == PaperCanvas.run_id(ord_after)
    end
  end

  describe "live task-block preview (t9) — parallel channel, save-stable (D5)" do
    test "the block the editor mounts stays a RAW query boundary — no snapshot injected" do
      blocks = [para("p1"), task_list("t1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, task_list("t1")},
               {:run, [para("p2")]}
             ]
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

  describe "task_block_preview (t9) — the boundary widget PAINTS the live rows" do
    import Phoenix.LiveViewTest

    alias Barkpark.PortableDoc.Render
    alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

    # The flag-ON editor render: canvas runs + boundary widgets. Static
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

    test "a resolved preview renders through the READER'S producer (rule 3), display-only (D5)" do
      block = task_list("t1")

      entry = %{
        "block_id" => "t1",
        "type" => "task-list",
        "snapshot" => [%{"title" => "Ship the seam", "status" => "ready"}]
      }

      html = editor_html([para("p1"), block, para("p2")], %{"t1" => entry})

      # The widget paints the live rows…
      assert html =~ ~s(data-test-id="paper-task-preview")
      assert html =~ "Ship the seam"

      # …as the EXACT bytes /papers would emit for the resolved block — one
      # producer, byte for byte (doctrine rule 3).
      resolved = TaskResolver.apply_preview(block, entry)
      assert html =~ Render.render_block(resolved, %{style: :article})

      # D5 in the DOM: the canvas seeds (the save baseline) still carry the raw
      # prose runs, and no resolved snapshot is ever serialized back into any
      # data-canvas-blocks / data-block editor state.
      assert html =~ ~s(data-canvas-blocks)
      refute html =~ ~s(&quot;snapshot&quot;)
    end

    test "an error entry degrades to the quiet plugin-off note" do
      entry = %{"block_id" => "t1", "type" => "task-list", "error" => true}
      html = editor_html([task_list("t1")], %{"t1" => entry})

      assert html =~ "Live task preview unavailable"
      refute html =~ "Loading live tasks"
    end

    test "a query block with no entry yet shows the honest loading note" do
      html = editor_html([task_list("t1")], %{})
      assert html =~ "Loading live tasks"
    end

    test "an author-pinned literal snapshot renders directly from its own rows" do
      pinned = %{
        "id" => "t1",
        "type" => "task-list",
        "snapshot" => [%{"title" => "Pinned row", "status" => "done"}]
      }

      html = editor_html([pinned], %{})
      assert html =~ "Pinned row"
      refute html =~ "Loading live tasks"
    end

    test "a matchless task-detail preview shows an explicit empty note, not a blank strip" do
      block = %{"id" => "d1", "type" => "task-detail", "query" => %{"nope" => 1}}
      entry = %{"block_id" => "d1", "type" => "task-detail", "task" => %{}}

      html = editor_html([block], %{"d1" => entry})
      assert html =~ "No matching tasks."
    end

    test "flag OFF: the shipped per-block list stays byte-free of any preview markup" do
      System.delete_env("BARKPARK_PAPER_CANVAS")

      html = editor_html([task_list("t1")], %{"t1" => %{"block_id" => "t1", "snapshot" => []}})
      refute html =~ "paper-task-preview"
    end
  end

  describe "paper_canvas_enabled?/0 (default FALSE)" do
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

    test "unset → false (the shipped default)" do
      System.delete_env("BARKPARK_PAPER_CANVAS")
      refute PaperCanvas.paper_canvas_enabled?()
    end

    test "empty / arbitrary values → false" do
      for v <- ["", "0", "off", "no", "false-ish", "  ", "2"] do
        System.put_env("BARKPARK_PAPER_CANVAS", v)
        refute PaperCanvas.paper_canvas_enabled?(), "expected #{inspect(v)} → false"
      end
    end

    test "truthy '1' / 'true' (case-insensitive, trimmed) → true" do
      for v <- ["1", "true", "TRUE", "True", " true ", "  1 "] do
        System.put_env("BARKPARK_PAPER_CANVAS", v)
        assert PaperCanvas.paper_canvas_enabled?(), "expected #{inspect(v)} → true"
      end
    end
  end
end
