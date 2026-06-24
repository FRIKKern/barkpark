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

  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

  defp para(id), do: %{"id" => id, "type" => "paragraph", "content" => []}
  defp heading(id), do: %{"id" => id, "type" => "heading", "text" => "H", "level" => 2}
  defp list(id), do: %{"id" => id, "type" => "list", "ordered" => false, "items" => []}
  defp callout(id), do: %{"id" => id, "type" => "callout", "tone" => "info"}
  defp divider(id), do: %{"id" => id, "type" => "divider"}
  defp field(id), do: %{"id" => id, "type" => "field-string", "value" => ""}
  defp sheet(id), do: %{"id" => id, "type" => "sheet", "rows" => []}
  defp code(id), do: %{"id" => id, "type" => "code", "value" => ""}
  defp diagram(id), do: %{"id" => id, "type" => "diagram", "source" => "", "caption" => ""}

  describe "partition_runs/1" do
    test "empty list → []" do
      assert PaperCanvas.partition_runs([]) == []
    end

    test "all-prose → a single maximal run" do
      blocks = [heading("h1"), para("p1"), list("l1"), para("p2")]
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "no canvas blocks → every block is its own boundary segment" do
      # divider IS canvas (S3) and callout IS canvas (S3.2), so this all-boundary
      # case uses field + sheet, which STILL split until their own S3 increments.
      blocks = [field("f1"), sheet("s1")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:block, field("f1")},
               {:block, sheet("s1")}
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

    test "S3.3: field / sheet / diagram STILL split a run (callout/divider/code aside)" do
      # divider IS canvas (S3), callout IS canvas (S3.2), code IS canvas (S3.3), so
      # the still-splitting boundaries are field / sheet / diagram.
      for boundary <- [field("b"), sheet("b"), diagram("b")] do
        blocks = [para("p1"), boundary, para("p2")]

        assert PaperCanvas.partition_runs(blocks) == [
                 {:run, [para("p1")]},
                 {:block, boundary},
                 {:run, [para("p2")]}
               ],
               "expected #{boundary["type"]} to split the run"
      end
    end

    # ── S3.3: the code block is now CANVAS-ELIGIBLE too — it no longer splits ────

    test "S3.3: a code block INSIDE prose keeps the run whole (was split by the code)" do
      blocks = [para("p1"), code("k1"), para("p2")]

      # All three are canvas-eligible (prose ∪ code attr-atom) ⇒ ONE maximal run.
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

    test "S3.2: a field STILL splits, with a callout riding each surrounding run" do
      # field-string is still a boundary; the callouts are canvas, so each rides
      # the prose run on its side of the field.
      blocks = [para("p1"), callout("c1"), field("f1"), callout("c2"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1"), callout("c1")]},
               {:block, field("f1")},
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
        field("f1"),
        para("p3")
      ]

      # As of S3.2 neither the callout NOR the divider splits — they ride the
      # leading run; only the field (still a boundary) splits it off from p3.
      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [heading("h1"), para("p1"), callout("c1"), para("p2"), list("l1"), divider("d1")]},
               {:block, field("f1")},
               {:run, [para("p3")]}
             ]
    end

    test "leading non-canvas then a run" do
      # field is still a boundary (callout is canvas as of S3.2, so it would merge).
      blocks = [field("f1"), para("p1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:block, field("f1")},
               {:run, [para("p1"), para("p2")]}
             ]
    end

    test "two non-canvas boundaries between two runs do NOT merge into one run" do
      # sheet + field — both still boundaries (callout/divider are canvas now).
      blocks = [para("p1"), sheet("s1"), field("f1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, sheet("s1")},
               {:block, field("f1")},
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
      refute PaperCanvas.prose?(field("f"))
      refute PaperCanvas.prose?(%{"id" => "x"})
      refute PaperCanvas.prose?(%{"type" => "code"})
    end
  end

  describe "canvas?/1 (S3.3: prose ∪ divider ∪ callout ∪ code)" do
    test "prose, divider, callout AND code are canvas-eligible; field/sheet/diagram are not" do
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
      # Still boundaries — not yet pulled into the canvas.
      refute PaperCanvas.canvas?(field("f"))
      refute PaperCanvas.canvas?(sheet("s"))
      refute PaperCanvas.canvas?(diagram("g"))
      refute PaperCanvas.canvas?(%{"id" => "x"})
    end
  end

  describe "run_id/1" do
    test "is the first block's id" do
      assert PaperCanvas.run_id([para("p1"), para("p2")]) == "p1"
      assert PaperCanvas.run_id([heading("h7")]) == "h7"
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
