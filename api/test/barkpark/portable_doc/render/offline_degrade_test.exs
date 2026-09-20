defmodule Barkpark.PortableDoc.Render.OfflineDegradeTest do
  @moduledoc """
  The OFFLINE-DEGRADE contract for the two query-backed task blocks that used to
  lie when the live data was absent (task pp-b-offline-degrade).

  A `task-detail` and a `roadmap` both carry a `query`. When that query resolves
  to nothing — an offline export, a wasm preview, a reader with no task
  substrate — the block must still SAY something true:

    * TASK-DETAIL — an unresolved detail renders a NAMED empty state on every
      Elixir surface (article HTML and email alike). No surface may answer with a
      visually empty string: a block that vanishes is indistinguishable from a
      block the author never wrote.
    * ROADMAP — `TaskResolver.row_from_task/1` emits NO schedule field, so a
      live-query roadmap has no geometry at all. The clamp's {0, 100} default
      turned that into N identical full-width bars — a confident, fabricated
      timeline. Geometry must come from one of the two documented sources (the
      block span + the row's own ISO dates, or an author-typed `left`/`width`
      number) or the block must say it cannot place the items.

  SCOPE, stated honestly: the surfaces asserted here are the ELIXIR renderers.
  The Go TUI (`internal/pdrender/taskblocks.go`) and the JS reader
  (`js/packages/react/src/blocks/`) carry their own twins of this copy and are
  NOT covered by this file — they are named in the PR as the owning lanes' half.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Components
  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.FleetEmail
  alias Barkpark.PortableDoc.TaskResolver

  # A stub fetcher with a HIT and a MISS arm, so a "renders the empty state"
  # assertion is never vacuous: the same resolver, driven by the same call,
  # produces real content for the hit.
  defp fetch(%{"hit" => true}),
    do: [%{"title" => "Ship the board", "lifecycle_status" => "in_progress"}]

  defp fetch(_), do: []

  defp resolve(block), do: TaskResolver.resolve([block], &fetch/1) |> hd()

  defp article(block), do: Compose.compose_block(block, :article)["html"]
  defp email(block), do: Compose.compose_block(block, :email)["html"]

  # ── task-detail: the unresolved block is VISIBLE on every surface ────────────

  describe "task-detail with no resolved task" do
    test "the resolver injects an empty task and BOTH surfaces name the empty state" do
      out = resolve(%{"type" => "task-detail", "query" => %{"hit" => false}})
      assert out["task"] == %{}

      html = article(out)
      mail = email(out)

      # the control: neither surface answers with nothing.
      refute html == ""
      refute mail == ""

      assert html =~ ~s(class="bp-tdetail bp-tdetail--empty")
      assert html =~ "No matching tasks."
      assert mail =~ "No matching tasks."
      assert mail =~ "task-detail"
    end

    test "CONTROL — the same block with a HIT renders the real card, not the placeholder" do
      out = resolve(%{"type" => "task-detail", "query" => %{"hit" => true}})

      html = article(out)
      mail = email(out)

      assert html =~ "Ship the board"
      refute html =~ "bp-tdetail--empty"
      assert mail =~ "Ship the board"
      refute mail =~ "No matching tasks."
    end

    test "every arity/theme of the email emitter names the empty state" do
      block = %{"type" => "task-detail", "task" => %{}}

      for mail <- [
            FleetEmail.task_detail_email_html(block),
            FleetEmail.task_detail_email_html(block, :ember),
            FleetEmail.task_detail_email_html(%{"type" => "task-detail"})
          ] do
        assert mail =~ "No matching tasks."
        refute mail == ""
      end
    end

    test "a blank-titled task is an unresolved task, whitespace included" do
      for t <- [%{}, %{"title" => ""}, %{"title" => "   "}] do
        block = %{"type" => "task-detail", "task" => t}
        assert Components.task_detail_html(block) =~ "bp-tdetail--empty"
        assert FleetEmail.task_detail_email_html(block) =~ "No matching tasks."
      end
    end

    test "a NON-MAP is not a block at all and still emits nothing (policy, both surfaces)" do
      # Documented divergence from the empty-state rule: a placeholder here would
      # claim a block exists where the document has none.
      assert Components.task_detail_html(nil) == ""
      assert FleetEmail.task_detail_email_html(nil) == ""
    end
  end

  # ── roadmap: geometry is read, never invented ────────────────────────────────

  describe "roadmap with no trustworthy geometry" do
    test "a live-query roadmap renders the cannot-place state, NOT one bar per row" do
      out =
        resolve(%{
          "type" => "roadmap",
          "query" => %{"hit" => true},
          "scale" => ["Q1", "Q2"]
        })

      # the precondition this whole criterion rests on: the resolver really does
      # emit rows, and really does emit NO geometry on them.
      assert [row] = out["snapshot"]
      refute Map.has_key?(row, "left")
      refute Map.has_key?(row, "width")
      refute Map.has_key?(row, "start")

      html = article(out)
      mail = email(out)

      assert html =~ Components.roadmap_unplaced_copy()
      refute html =~ "bp-rm__bar"
      refute html =~ "bp-rm__lanes"
      # the items are not DROPPED, only un-placed: the row still reaches the page.
      assert html =~ "Ship the board"

      assert mail =~ Components.roadmap_unplaced_copy()
      assert mail =~ "Ship the board"
    end

    test "a MULTI-row live roadmap would have been N identical full-width bars" do
      rows = for t <- ~w(a b c), do: %{"title" => t, "status" => "open"}
      block = %{"type" => "roadmap", "snapshot" => rows}

      html = Components.roadmap_html(block)

      refute html =~ "bp-rm__bar"
      assert html =~ Components.roadmap_unplaced_copy()
      for t <- ~w(a b c), do: assert(html =~ ~s(>#{t}<))
    end

    test "CONTROL — author pct geometry still draws real bars (v1 path untouched)" do
      block = %{
        "type" => "roadmap",
        "snapshot" => [
          %{"title" => "Foundation", "status" => "done", "left" => 0, "width" => 40},
          %{"title" => "Ship", "status" => "in_progress", "left" => 40, "width" => 35}
        ]
      }

      html = Components.roadmap_html(block)

      assert html =~ ~s(style="left:0%;width:40%")
      assert html =~ ~s(style="left:40%;width:35%")
      refute html =~ Components.roadmap_unplaced_copy()
      refute html =~ "bp-rm__lane--unplaced"

      mail = FleetEmail.roadmap_email_html(block)
      assert mail =~ "<table"
      refute mail =~ Components.roadmap_unplaced_copy()
    end

    test "CONTROL — date-rail geometry is a trustworthy source on both surfaces" do
      block = %{
        "type" => "roadmap",
        "start" => "2026-01-01",
        "end" => "2026-01-11",
        "snapshot" => [
          %{
            "title" => "Dated",
            "status" => "done",
            "start" => "2026-01-01",
            "end" => "2026-01-06"
          }
        ]
      }

      html = Components.roadmap_html(block)
      assert html =~ "bp-rm__bar"
      refute html =~ Components.roadmap_unplaced_copy()

      # email has no date MATH, but it must agree on the QUESTION: a dated row is
      # placeable, so the inbox keeps drawing a bar where the reader draws one.
      mail = FleetEmail.roadmap_email_html(block)
      refute mail =~ Components.roadmap_unplaced_copy()
      refute mail =~ Components.roadmap_lane_unplaced_copy()
    end

    test "PARTIAL geometry: placed lanes keep their bars, unplaced lanes draw none" do
      block = %{
        "type" => "roadmap",
        "snapshot" => [
          %{"title" => "Placed", "status" => "done", "left" => 10, "width" => 20},
          %{"title" => "Unplaced", "status" => "open"}
        ]
      }

      html = Components.roadmap_html(block)

      assert html =~ ~s(style="left:10%;width:20%")
      assert html =~ "bp-rm__lane--unplaced"
      assert html =~ Components.roadmap_lane_unplaced_copy()
      # the unplaced lane must NOT have acquired the clamp default.
      refute html =~ ~s(style="left:0%;width:100%")
      # exactly one bar for two lanes.
      assert length(String.split(html, "bp-rm__bar bp-rm__bar--")) == 2
      # the labels of BOTH rows survive — the lane is degraded, not dropped.
      assert html =~ "Placed"
      assert html =~ "Unplaced"

      mail = FleetEmail.roadmap_email_html(block)
      assert mail =~ Components.roadmap_lane_unplaced_copy()
      assert mail =~ "Unplaced"
      assert mail =~ "Placed"
    end

    test "a partly-dated row (start only) is NOT placeable" do
      block = %{
        "type" => "roadmap",
        "start" => "2026-01-01",
        "end" => "2026-01-11",
        "snapshot" => [%{"title" => "Half", "status" => "open", "start" => "2026-01-02"}]
      }

      assert Components.roadmap_html(block) =~ Components.roadmap_unplaced_copy()
    end

    test "a row with dates but NO block span is not placeable (no span to measure against)" do
      block = %{
        "type" => "roadmap",
        "snapshot" => [
          %{
            "title" => "Dated",
            "status" => "open",
            "start" => "2026-01-01",
            "end" => "2026-01-06"
          }
        ]
      }

      assert Components.roadmap_html(block) =~ Components.roadmap_unplaced_copy()
    end

    test "an empty snapshot keeps its OWN copy — no-items is not no-schedule" do
      html = Components.roadmap_html(%{"type" => "roadmap", "snapshot" => []})

      assert html =~ "No roadmap items."
      refute html =~ Components.roadmap_unplaced_copy()
    end
  end

  # ── escape safety on every string that reaches the new paths ─────────────────

  describe "malicious author text on the degraded paths" do
    @evil "<script>alert(1)</script>&\"x\">"

    test "an unplaced lane label is escaped on both surfaces" do
      block = %{
        "type" => "roadmap",
        "snapshot" => [
          %{"title" => "ok", "status" => "done", "left" => 0, "width" => 10},
          %{"title" => @evil, "status" => "open"}
        ]
      }

      for out <- [Components.roadmap_html(block), FleetEmail.roadmap_email_html(block)] do
        refute out =~ "<script>"
        assert out =~ "&lt;script&gt;"
      end
    end

    test "author text in a geometry FIELD cannot reach a style attribute" do
      # `left`/`width` are only ever trusted when they are NUMBERS, so a string
      # payload makes the row unplaceable rather than an injected style value.
      block = %{
        "type" => "roadmap",
        "snapshot" => [
          %{"title" => "x", "status" => "open", "left" => "0;\" onload=\"e", "width" => 50}
        ]
      }

      html = Components.roadmap_html(block)

      refute html =~ "onload"
      refute html =~ "bp-rm__lane--unplaced"
      # `width` is a number, so the row IS placeable and the string `left` clamps
      # to 0 — the pre-existing clampf contract, not a new escape surface.
      assert html =~ ~s(style="left:0%;width:50%")
    end

    test "an unresolved task-detail carrying evil sibling fields still renders the placeholder" do
      block = %{"type" => "task-detail", "task" => %{"title" => "", "status" => @evil}}

      for out <- [
            Components.task_detail_html(block),
            FleetEmail.task_detail_email_html(block)
          ] do
        refute out =~ "<script>"
        assert out =~ "No matching tasks."
      end
    end
  end

  # ── the two surfaces share ONE copy, they do not each retype it ──────────────

  test "the unplaced copy is a single source both surfaces read" do
    assert Components.roadmap_unplaced_copy() != ""
    assert Components.roadmap_lane_unplaced_copy() != ""

    rows = [%{"title" => "a", "status" => "open"}]
    block = %{"type" => "roadmap", "snapshot" => rows}

    assert Components.roadmap_html(block) =~ Components.roadmap_unplaced_copy()
    assert FleetEmail.roadmap_email_html(block) =~ Components.roadmap_unplaced_copy()
  end
end
