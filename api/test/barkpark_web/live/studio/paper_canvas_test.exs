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

  describe "partition_runs/1" do
    test "empty list → []" do
      assert PaperCanvas.partition_runs([]) == []
    end

    test "all-prose → a single maximal run" do
      blocks = [heading("h1"), para("p1"), list("l1"), para("p2")]
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "no canvas blocks → every block is its own boundary segment" do
      # callout + field are non-canvas; a divider IS canvas (S3), so this set
      # avoids the divider to stay an all-boundary case.
      blocks = [callout("c1"), field("f1")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:block, callout("c1")},
               {:block, field("f1")}
             ]
    end

    # ── S3: the divider is CANVAS-ELIGIBLE — it no longer splits a run ──────────

    test "S3: a divider INSIDE prose keeps the run whole (was split by the divider)" do
      blocks = [heading("h1"), para("p1"), divider("d1"), para("p2")]

      # All four are canvas-eligible (prose ∪ divider) ⇒ ONE maximal run.
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "S3: a callout STILL splits a run (only the divider became canvas-eligible)" do
      blocks = [para("p1"), callout("c1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, callout("c1")},
               {:run, [para("p2")]}
             ]
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

    test "S3: a divider directly AFTER a callout opens a fresh run with the divider" do
      # callout (boundary) breaks the run; the divider is canvas-eligible so it
      # OPENS the next run, which the following paragraph extends.
      blocks = [para("p1"), callout("c1"), divider("d1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, callout("c1")},
               {:run, [divider("d1"), para("p2")]}
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

      # The divider no longer splits — it rides the {p2, list, divider} run; the
      # callout and field STILL split.
      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [heading("h1"), para("p1")]},
               {:block, callout("c1")},
               {:run, [para("p2"), list("l1"), divider("d1")]},
               {:block, field("f1")},
               {:run, [para("p3")]}
             ]
    end

    test "leading non-canvas then a run" do
      blocks = [callout("c1"), para("p1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:block, callout("c1")},
               {:run, [para("p1"), para("p2")]}
             ]
    end

    test "two non-canvas boundaries between two runs do NOT merge into one run" do
      blocks = [para("p1"), callout("c1"), field("f1"), para("p2")]

      assert PaperCanvas.partition_runs(blocks) == [
               {:run, [para("p1")]},
               {:block, callout("c1")},
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
    test "paragraph / heading / list are prose; everything else (incl. divider) is not" do
      assert PaperCanvas.prose?(para("p"))
      assert PaperCanvas.prose?(heading("h"))
      assert PaperCanvas.prose?(list("l"))
      refute PaperCanvas.prose?(callout("c"))
      # A divider is canvas-eligible but NOT prose — it is an atom, not a textblock.
      refute PaperCanvas.prose?(divider("d"))
      refute PaperCanvas.prose?(field("f"))
      refute PaperCanvas.prose?(%{"id" => "x"})
      refute PaperCanvas.prose?(%{"type" => "code"})
    end
  end

  describe "canvas?/1 (S3: prose ∪ divider)" do
    test "prose AND divider are canvas-eligible; other non-prose blocks are not" do
      assert PaperCanvas.canvas?(para("p"))
      assert PaperCanvas.canvas?(heading("h"))
      assert PaperCanvas.canvas?(list("l"))
      # The S3 addition: a divider is now canvas-eligible (an atom node inside the run).
      assert PaperCanvas.canvas?(divider("d"))
      # Still boundaries — not yet pulled into the canvas.
      refute PaperCanvas.canvas?(callout("c"))
      refute PaperCanvas.canvas?(field("f"))
      refute PaperCanvas.canvas?(%{"id" => "x"})
      refute PaperCanvas.canvas?(%{"type" => "code"})
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
