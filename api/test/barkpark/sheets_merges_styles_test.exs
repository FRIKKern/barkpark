defmodule Barkpark.SheetsMergesStylesTest do
  @moduledoc """
  M5 core data-model extension: tab-level `"merges"` and cell-level `"s"`
  styles through snapshot synthesis (`Barkpark.Plugins.Sheets.Core.snapshot_for/2`) and
  the HTML walker (`Barkpark.PortableDoc.Render`). Pure functions, no DB.

  Fidelity contract under test: the HTML render honors merges
  (colspan/rowspan, covered cells emit no `<td>`) and basic styles; the
  PdSheet node keeps the dense value grid unchanged, so the TUI renders the
  merged value at its anchor cell and ignores both keys.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.Plugins.Sheets.Core, as: Sheets

  defp content(tab), do: %{"tabs" => [tab]}

  defp render_sheet(snapshot, opts \\ %{}) do
    Render.render_block(
      %{"type" => "sheet", "snapshot" => snapshot},
      Map.put(opts, :doctype, false)
    )
  end

  # ── snapshot: merges ────────────────────────────────────────────────────────

  describe "snapshot_for/2 — merges" do
    test "merges encode 0-based [row, col, rowspan, colspan] against the body grid" do
      snap =
        content(%{
          "cells" => %{"A1" => %{"v" => "Title"}, "B2" => %{"v" => "x"}},
          "merges" => ["A1:B1"]
        })
        |> Sheets.snapshot_for(0)

      assert snap["merges"] == [[0, 0, 1, 2]]
      assert snap["rows"] == [["Title", ""], ["", "x"]]
    end

    test "merge ranges never extend the grid — they clip to the occupied bounds" do
      snap =
        content(%{"cells" => %{"A1" => %{"v" => "wide"}}, "merges" => ["A1:C2"]})
        |> Sheets.snapshot_for(0)

      assert snap == %{"rows" => [["wide"]]}
    end

    test "a hostile merge range cannot inflate the dense grid" do
      snap =
        content(%{"cells" => %{"A1" => %{"v" => "x"}}, "merges" => ["A1:ZZZ1000000"]})
        |> Sheets.snapshot_for(0)

      assert snap == %{"rows" => [["x"]]}
    end

    test "a merge within the occupied bounds clips to them" do
      snap =
        content(%{
          "cells" => %{"A1" => %{"v" => "band"}, "B2" => %{"v" => "y"}},
          "merges" => ["A1:C3"]
        })
        |> Sheets.snapshot_for(0)

      assert snap["rows"] == [["band", ""], ["", "y"]]
      assert snap["merges"] == [[0, 0, 2, 2]]
    end

    test "a merge touching a frozen head row clips to the body" do
      snap =
        content(%{
          "frozen_rows" => 1,
          "cells" => %{"A1" => %{"v" => "H"}, "A2" => %{"v" => "v"}, "B3" => %{"v" => "w"}},
          "merges" => ["A1:A3"]
        })
        |> Sheets.snapshot_for(0)

      # head is row 1; the merge keeps only body rows 2..3 → rows 0..1
      assert snap["head"] == ["H", ""]
      assert snap["merges"] == [[0, 0, 2, 1]]
    end

    test "a merge that clips to a single cell is dropped, as are malformed entries" do
      snap =
        content(%{
          "frozen_rows" => 1,
          "cells" => %{"A1" => %{"v" => "H"}, "A2" => %{"v" => "v"}},
          "merges" => ["A1:A2", "bogus", "A1:?", 42, "B1:B1"]
        })
        |> Sheets.snapshot_for(0)

      refute Map.has_key?(snap, "merges")
    end

    test "reversed corners normalize" do
      snap =
        content(%{
          "cells" => %{"A1" => %{"v" => "x"}, "B2" => %{"v" => "y"}},
          "merges" => ["B2:A1"]
        })
        |> Sheets.snapshot_for(0)

      assert snap["merges"] == [[0, 0, 2, 2]]
    end
  end

  # ── snapshot: dense grid bound ──────────────────────────────────────────────

  describe "snapshot_for/2 — 200_000-position dense grid bound" do
    test "sparse extremes truncate rows; all occupied columns are kept" do
      snap =
        content(%{"cells" => %{"A1" => %{"v" => "a"}, "CV1500000" => %{"v" => "z"}}})
        |> Sheets.snapshot_for(0)

      # CV = col 100 → 200_000 / 100 = 2_000 full rows fit
      assert length(snap["rows"]) == 2_000
      assert length(hd(snap["rows"])) == 100
      assert hd(hd(snap["rows"])) == "a"
    end

    test "columns clamp against the cap too — wide legacy content stays within 200k positions" do
      # ZZZZ = col 475_254: the gate rejects it on save, but legacy rows
      # may store it — columns truncate to the cap, leaving one full row
      snap =
        content(%{"cells" => %{"A1" => %{"v" => "a"}, "ZZZZ1" => %{"v" => "z"}}})
        |> Sheets.snapshot_for(0)

      assert [row] = snap["rows"]
      assert length(row) == 200_000
      assert hd(row) == "a"
    end

    test "a ZZZZZZZZ1-class ref cannot inflate the grid (dims stay bounded)" do
      # ZZZZZZZZ ≈ col 2.17e11 — without the column clamp the dense
      # comprehension would hang/OOM; with it the dims stay cap-bounded
      snap = content(%{"cells" => %{"ZZZZZZZZ1" => %{"v" => "far"}}}) |> Sheets.snapshot_for(0)

      assert [row] = snap["rows"]
      assert length(row) == 200_000
      assert Enum.all?(row, &(&1 == ""))
    end

    test "merges clip to the truncated bounds" do
      snap =
        content(%{
          "cells" => %{"A1" => %{"v" => "a"}, "CV1500000" => %{"v" => "z"}},
          "merges" => ["A1:A2500"]
        })
        |> Sheets.snapshot_for(0)

      assert snap["merges"] == [[0, 0, 2_000, 1]]
    end
  end

  # ── snapshot: styles ────────────────────────────────────────────────────────

  describe "snapshot_for/2 — styles" do
    test "styles project to a sparse 0-based row,col map, sanitized" do
      snap =
        content(%{
          "cells" => %{
            "A1" => %{"v" => "bold", "s" => %{"b" => true}},
            "B2" => %{
              "v" => "full",
              "s" => %{"i" => true, "bg" => "#FFCC00", "al" => "center"}
            }
          }
        })
        |> Sheets.snapshot_for(0)

      assert snap["styles"] == %{
               "0,0" => %{"b" => true},
               "1,1" => %{"i" => true, "bg" => "#ffcc00", "al" => "center"}
             }
    end

    test "invalid style values drop; an all-invalid style map drops the cell entry" do
      snap =
        content(%{
          "cells" => %{
            "A1" => %{"v" => "x", "s" => %{"b" => "yes", "bg" => "red", "al" => "top"}},
            "B1" => %{"v" => "y", "s" => %{"b" => false, "i" => true, "bg" => "#12345"}}
          }
        })
        |> Sheets.snapshot_for(0)

      assert snap["styles"] == %{"0,1" => %{"i" => true}}
    end

    test "styles on a frozen head row are dropped" do
      snap =
        content(%{
          "frozen_rows" => 1,
          "cells" => %{
            "A1" => %{"v" => "H", "s" => %{"b" => true}},
            "A2" => %{"v" => "v", "s" => %{"b" => true}}
          }
        })
        |> Sheets.snapshot_for(0)

      assert snap["styles"] == %{"0,0" => %{"b" => true}}
    end

    test "a tab with neither merges nor styles snapshots byte-identically to M0" do
      snap = content(%{"cells" => %{"A1" => %{"v" => "x"}}}) |> Sheets.snapshot_for(0)
      assert snap == %{"rows" => [["x"]]}
    end
  end

  # ── compose: PdSheet pass-through ───────────────────────────────────────────

  describe "compose_block/2 — merges + styles ride the PdSheet node" do
    test "valid merges and styles pass through; malformed merge entries drop" do
      block = %{
        "type" => "sheet",
        "snapshot" => %{
          "rows" => [["a", "b"], ["c", "d"]],
          "merges" => [[0, 0, 1, 2], ["x"], [0, 0, 0, 0]],
          "styles" => %{"0,0" => %{"b" => true}}
        }
      }

      pd = Render.compose_block(block)

      assert pd["merges"] == [[0, 0, 1, 2]]
      assert pd["styles"] == %{"0,0" => %{"b" => true}}
      # the dense grid is untouched — the TUI keeps anchor-cell fidelity
      assert pd["rows"] == [["a", "b"], ["c", "d"]]
    end

    test "absent merges/styles compose to a node without the keys" do
      pd = Render.compose_block(%{"type" => "sheet", "snapshot" => %{"rows" => [["a"]]}})
      refute Map.has_key?(pd, "merges")
      refute Map.has_key?(pd, "styles")
    end
  end

  # ── walk: HTML emission ─────────────────────────────────────────────────────

  describe "PdSheet HTML — merges and styles" do
    test "colspan/rowspan emit at the anchor; covered cells emit no <td>" do
      html =
        render_sheet(%{
          "rows" => [["Title", ""], ["a", "b"]],
          "merges" => [[0, 0, 1, 2]]
        })

      assert html =~ ~s(colspan="2")
      refute html =~ "rowspan"
      # row 1: one merged td; row 2: two plain tds → 3 total
      assert length(String.split(html, "<td")) - 1 == 3
    end

    test "rowspan emits for vertical merges" do
      html =
        render_sheet(%{
          "rows" => [["tall", "x"], ["", "y"]],
          "merges" => [[0, 0, 2, 1]]
        })

      assert html =~ ~s(rowspan="2")
      assert length(String.split(html, "<td")) - 1 == 3
    end

    test "styles emit as inline css, sanitized" do
      html =
        render_sheet(%{
          "rows" => [["b", "i", "bg", "al"]],
          "styles" => %{
            "0,0" => %{"b" => true},
            "0,1" => %{"i" => true},
            "0,2" => %{"bg" => "#ffcc00"},
            "0,3" => %{"al" => "right"}
          }
        })

      assert html =~ "font-weight:bold;"
      assert html =~ "font-style:italic;"
      assert html =~ "background:#ffcc00;"
      assert html =~ "text-align:right;"
    end

    test "a hostile bg value never reaches the style attribute" do
      html =
        render_sheet(%{
          "rows" => [["x"]],
          "styles" => %{"0,0" => %{"bg" => ~s(#fff" onmouseover="evil)}}
        })

      refute html =~ "evil"
      refute html =~ "background:"
    end

    test "no-merge no-style output is byte-identical to the pre-M5 shape" do
      snapshot = %{"head" => ["H"], "rows" => [["v"]], "col_widths" => [100]}
      html = render_sheet(snapshot)

      assert html =~ ~s(<td style="width:100px;border:1px solid)
      assert html =~ ~s(vertical-align:top">v</td>)
    end

    test "article palette renders merges + styles too" do
      html =
        render_sheet(
          %{
            "rows" => [["Title", ""], ["a", "b"]],
            "merges" => [[0, 0, 1, 2]],
            "styles" => %{"1,0" => %{"b" => true}}
          },
          %{style: :article}
        )

      assert html =~ ~s(colspan="2")
      assert html =~ "font-weight:bold;"
    end
  end
end
