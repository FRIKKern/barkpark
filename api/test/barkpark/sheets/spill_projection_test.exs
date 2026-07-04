defmodule Barkpark.Sheets.SpillProjectionTest do
  @moduledoc """
  Dynamic-array SPILL — the cross-surface + conditional-formatting PROJECTION
  LOCK (arc-4 wave-3 slice S3).

  This slice proves design decision 3 / CT-D3 (`bp-sheets-aa-crosstab-design.md`
  §3.3, §5 wave-3): spilled cells are ENGINE-MATERIALIZED into the sparse
  `"cells"` map as ordinary stored cells that additionally carry a `"spill"`
  marker (and, on the anchor, `"spill_dims"`). Because every read surface
  projects a cell's stored `"v"` through `Core.display_value/1` — knowing
  NOTHING about the `"spill"` marker — a spilled value renders on all five
  surfaces (snapshot / paper embed / CSV / MD / HTML / TUI) and earns
  conditional formatting for FREE, with ZERO renderer or CF change. That "free
  projection" is the design's whole reason to materialize (vs a non-stored
  overlay), and this file is its regression wall.

  ## What this file DOES and does NOT exercise

  - It SEEDS the materialized spill shape from §3.3 directly into a document and
    asserts projection. It does NOT invoke the engine: the engine's spill
    distribution + `#SPILL!` + array literals is the parallel slice S1
    (`engine.ex`, sole writer), not yet landed. When S1 lands, a recompute of
    the same `=SORT(...)` / `={…}` anchor writes byte-identically this cells map
    (the §3.3 shape IS the contract), so this lock certifies the PROJECTION half
    of the acceptance (`§3.3: "a spilled cell shows in a paper embed + CSV
    export … CF colors a spilled cell by its value"`) independent of S1/S2.
  - It makes NO production change: the design predicts none is needed. If a
    surface had failed to project a materialized spill cell, that would be a
    genuine gap to fix in `core.ex` (the licensed file) — none was found.

  The materialized shape (design §3.3):

      anchor A1: %{"f" => "={111;222;333}", "v" => 111, "t" => "n",
                   "spill" => "A1", "spill_dims" => [3, 1]}
      spill  A2: %{"v" => 222, "t" => "n", "spill" => "A1"}   # engine-written
      spill  A3: %{"v" => 333, "t" => "n", "spill" => "A1"}   # engine-written
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Csv
  alias Barkpark.Plugins.Sheets.Html
  alias Barkpark.Plugins.Sheets.Markdown
  alias Barkpark.PortableDoc.Render

  # The three distinctive spilled sentinels. Chosen so a non-materialized spill
  # (only the anchor stored, the design's F6 collapse) leaves 222/333 ABSENT
  # from every surface — every assertion below is fail-meaningful against a blank
  # (or `#SPILL!`) cell, never "merely non-empty".
  @anchor_v 111
  @spill_v2 222
  @spill_v3 333

  # A single-column array-literal spill in A1:A3 — self-contained (no source
  # column), the design's array-literal case verbatim (`={111;222;333}`).
  # A2/A3 are engine-owned marked cells; only their stored `"v"` matters to a
  # projection surface.
  defp spilled_content do
    %{
      "tabs" => [
        %{
          "name" => "Sheet1",
          "cells" => %{
            "A1" => %{
              "f" => "={111;222;333}",
              "v" => @anchor_v,
              "t" => "n",
              "spill" => "A1",
              "spill_dims" => [3, 1]
            },
            "A2" => %{"v" => @spill_v2, "t" => "n", "spill" => "A1"},
            "A3" => %{"v" => @spill_v3, "t" => "n", "spill" => "A1"}
          }
        }
      ]
    }
  end

  # The SAME cells with every spill marker key stripped — pure user-authored
  # values. Used as the projection-invisibility control: a materialized spill
  # must project byte-identically to a plain sheet carrying the same `"v"`s.
  defp plain_content do
    %{
      "tabs" => [
        %{
          "name" => "Sheet1",
          "cells" => %{
            "A1" => %{"v" => @anchor_v, "t" => "n"},
            "A2" => %{"v" => @spill_v2, "t" => "n"},
            "A3" => %{"v" => @spill_v3, "t" => "n"}
          }
        }
      ]
    }
  end

  defp cf_rule(range, op, value, style) do
    %{"range" => range, "when" => %{"op" => op, "value" => value}, "style" => style}
  end

  # ── (a) Core.snapshot_for — the dense "rows" grid ──────────────────────────

  describe "spill projection — (a) snapshot rows grid" do
    test "every materialized spilled value lands in the dense grid, in order" do
      snapshot = Core.snapshot_for(spilled_content())

      # The concrete spilled values, at the exact positions the anchor spilled
      # into — NOT a lone anchor row (which is what a non-materialized/F6-collapse
      # spill would project).
      assert snapshot["rows"] == [["111"], ["222"], ["333"]]
    end
  end

  # ── (b) paper embed / PortableDoc render ───────────────────────────────────

  describe "spill projection — (b) paper embed (PortableDoc.Render)" do
    test "a sheet embed block carrying the snapshot renders the spilled values as <td>s" do
      block = %{
        "id" => "s1",
        "type" => "sheet",
        "ref" => "sheet-spill",
        "snapshot" => Core.snapshot_for(spilled_content())
      }

      html = Render.render_block(block)

      assert html =~ "<table"
      # The engine-written spilled cells, not just the anchor.
      assert html =~ ">222<"
      assert html =~ ">333<"
    end
  end

  # ── (c) CSV export ─────────────────────────────────────────────────────────

  describe "spill projection — (c) CSV export" do
    test "CSV carries each spilled value on its own row" do
      assert {:ok, csv} = Csv.export(spilled_content())

      # Row-major CRLF grid — one spilled value per line.
      assert csv == "111\r\n222\r\n333\r\n"
    end
  end

  # ── (d) Markdown + HTML export ─────────────────────────────────────────────

  describe "spill projection — (d) Markdown + standalone-HTML export" do
    test "Markdown export renders the spilled values in the table body" do
      md = Markdown.export(spilled_content())

      assert md =~ "222"
      assert md =~ "333"
    end

    test "standalone HTML export renders the spilled values in <td>s" do
      html = Html.export(spilled_content(), "Spill")

      assert html =~ "<!doctype html>"
      assert html =~ ">222<"
      assert html =~ ">333<"
    end
  end

  # ── (e) TUI snapshot (pdrender contract) ───────────────────────────────────

  describe "spill projection — (e) TUI snapshot" do
    # The Go TUI's pdrender consumes the `"sheet"` embed block's snapshot and
    # renders its `"rows"` as text (ignoring styles/merges — values-first
    # fidelity, per Core's moduledoc). It's a separate binary, not callable from
    # ExUnit, so the snapshot the block hands it IS the TUI contract surface: if
    # the spilled value is in the rows grid, pdrender prints it.
    test "the embed-block snapshot the TUI ingests carries the spilled values in its rows" do
      block = %{
        "type" => "sheet",
        "tab" => 0,
        "snapshot" => Core.snapshot_for(spilled_content())
      }

      rows = block["snapshot"]["rows"]

      assert ["222"] in rows
      assert ["333"] in rows
      # And they survive a round-trip through the embed-block value (what the
      # TUI actually reads) — a lone anchor grid would fail this.
      assert rows == [["111"], ["222"], ["333"]]
    end
  end

  # ── THE CF LOCK: conditional formatting composes over a spilled cell's v ────

  describe "CF over a spilled cell (CF-D3 / CF-D9 kernel path, zero CF change)" do
    test "a {gt 150 -> red bg} rule colors the spilled cells by their MATERIALIZED v" do
      content =
        put_in(
          spilled_content(),
          ["tabs", Access.at(0), "cond_formats"],
          [cf_rule("A1:A3", "gt", 150, %{"bg" => "#ff0000"})]
        )

      snapshot = Core.snapshot_for(content)

      # A1 (111) does NOT exceed 150 → no style; A2 (222) and A3 (333) DO. The
      # rule fires on the engine-written spilled `"v"` exactly as it would on a
      # user-typed value — CondFormat.style_for evaluates the raw cell, which
      # for a spilled cell carries a real `"v"`. Body rows 1 and 2, col 0.
      assert snapshot["styles"] == %{
               "1,0" => %{"bg" => "#ff0000"},
               "2,0" => %{"bg" => "#ff0000"}
             }
    end

    test "CF composes per-key with a manual style on the ANCHOR cell" do
      # The anchor keeps user authoring (it owns the formula); a spilled cell
      # carries no user style (design §3.3). Prove CF composes with an anchor's
      # manual style the same way it does for any cell: bg from CF, al from
      # manual. Threshold gt 100 → anchor (111) now also matches.
      content =
        spilled_content()
        |> put_in(["tabs", Access.at(0), "cells", "A1", "s"], %{"al" => "center"})
        |> put_in(
          ["tabs", Access.at(0), "cond_formats"],
          [cf_rule("A1:A3", "gt", 100, %{"bg" => "#00ff00"})]
        )

      snapshot = Core.snapshot_for(content)

      assert snapshot["styles"]["0,0"] == %{"al" => "center", "bg" => "#00ff00"}
      assert snapshot["styles"]["1,0"] == %{"bg" => "#00ff00"}
      assert snapshot["styles"]["2,0"] == %{"bg" => "#00ff00"}
    end
  end

  # ── the "free projection" invariant, stated directly ───────────────────────

  describe "projection invariance — the spill markers are invisible to every surface" do
    # The strongest form of "spill renders for free": a materialized spill and a
    # plain sheet carrying the SAME `"v"`s must project BYTE-IDENTICALLY on every
    # surface. If any surface special-cased the `"spill"`/`"spill_dims"` keys
    # (dropped the cell, annotated it, skipped it), one of these equalities would
    # break. This is the CT-D3 lock AND the no-spill regression half in one: a
    # no-spill doc's snapshot/exports are byte-identical to the spilled doc's.
    test "snapshot_for is byte-identical with and without the spill markers" do
      assert Core.snapshot_for(spilled_content()) == Core.snapshot_for(plain_content())
    end

    test "CSV export is byte-identical with and without the spill markers" do
      assert Csv.export(spilled_content()) == Csv.export(plain_content())
    end

    test "Markdown export is byte-identical with and without the spill markers" do
      assert Markdown.export(spilled_content()) == Markdown.export(plain_content())
    end

    test "standalone HTML export is byte-identical with and without the spill markers" do
      assert Html.export(spilled_content(), "T") == Html.export(plain_content(), "T")
    end

    test "the paper embed render is byte-identical with and without the spill markers" do
      block = fn content ->
        %{"id" => "s", "type" => "sheet", "snapshot" => Core.snapshot_for(content)}
      end

      assert Render.render_block(block.(spilled_content())) ==
               Render.render_block(block.(plain_content()))
    end
  end

  # ── blocked spill projects #SPILL! at the anchor, nothing below ────────────

  describe "blocked spill (#SPILL!) projection" do
    # Design §3.3: a spill blocked by existing content yields `#SPILL!` at the
    # anchor and writes NOTHING to the target region. That's an engine decision
    # (S1), but the PROJECTION consequence is this file's concern: the anchor's
    # `#SPILL!` error string projects like any `t:"e"` cell, and the would-be
    # spilled cells are simply absent (blank). A blocked spill must never leak a
    # stale 222/333.
    defp blocked_content do
      %{
        "tabs" => [
          %{
            "name" => "Sheet1",
            "cells" => %{
              "A1" => %{"f" => "={111;222;333}", "v" => "#SPILL!", "t" => "e", "spill" => "A1"},
              # A2 holds pre-existing USER content that blocked the spill.
              "A2" => %{"v" => "blocker", "t" => "s"}
            }
          }
        ]
      }
    end

    test "#SPILL! shows at the anchor and no spilled value is projected anywhere" do
      snapshot = Core.snapshot_for(blocked_content())

      assert snapshot["rows"] == [["#SPILL!"], ["blocker"]]

      {:ok, csv} = Csv.export(blocked_content())
      assert csv =~ "#SPILL!"
      refute csv =~ "222"
      refute csv =~ "333"

      html =
        Render.render_block(%{
          "type" => "sheet",
          "snapshot" => snapshot
        })

      assert html =~ "#SPILL!"
      refute html =~ ">222<"
      refute html =~ ">333<"
    end
  end
end
