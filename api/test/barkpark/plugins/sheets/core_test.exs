defmodule Barkpark.Plugins.Sheets.CoreTest do
  @moduledoc """
  Unit locks for `Barkpark.Plugins.Sheets.Core` — A1 address helpers and
  snapshot synthesis. Pure functions, no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Engine

  # Build a conditional-formatting rule map for the projection tests.
  defp cf_rule(range, op, value, style) do
    %{"range" => range, "when" => %{"op" => op, "value" => value}, "style" => style}
  end

  # ── parse_ref/1 ─────────────────────────────────────────────────────────────

  describe "parse_ref/1" do
    test "single-letter columns map to correct 1-based index" do
      assert Core.parse_ref("A1") == {:ok, {1, 1}}
      assert Core.parse_ref("Z1") == {:ok, {26, 1}}
    end

    test "multi-letter columns use bijective base-26" do
      assert Core.parse_ref("AA3") == {:ok, {27, 3}}
      assert Core.parse_ref("AZ1") == {:ok, {52, 1}}
    end

    test "lowercase letters are accepted" do
      assert Core.parse_ref("a1") == {:ok, {1, 1}}
      assert Core.parse_ref("aa3") == {:ok, {27, 3}}
    end

    test "malformed addresses return :error" do
      assert Core.parse_ref("bad") == :error
      assert Core.parse_ref("A0") == :error
      assert Core.parse_ref("1A") == :error
      assert Core.parse_ref("") == :error
    end

    test "a trailing newline is rejected (`\\z`, not `$` — no PCRE stowaway)" do
      # `$` matched before a trailing newline, so "B2\n" used to parse as {2, 2};
      # the A1 regex is `\z`-anchored now, so a stowaway newline is :error.
      assert Core.parse_ref("B2\n") == :error
      assert Core.parse_ref("A1\n") == :error
      assert Core.parse_ref("AA3\r\n") == :error
    end

    test "non-binary input returns :error" do
      assert Core.parse_ref(nil) == :error
      assert Core.parse_ref(42) == :error
    end
  end

  # ── format_ref/1 ────────────────────────────────────────────────────────────

  describe "format_ref/1" do
    test "single-letter columns" do
      assert Core.format_ref({1, 1}) == "A1"
      assert Core.format_ref({26, 5}) == "Z5"
    end

    test "multi-letter columns" do
      assert Core.format_ref({27, 3}) == "AA3"
      assert Core.format_ref({52, 1}) == "AZ1"
    end

    test "parse_ref and format_ref are inverse" do
      for {col, row} <- [{1, 1}, {26, 1}, {27, 3}, {52, 10}, {703, 100}] do
        assert {:ok, ^col} =
                 Core.format_ref({col, row})
                 |> Core.parse_ref()
                 |> then(fn {:ok, {c, _}} -> {:ok, c} end)
      end
    end
  end

  # ── snapshot_for/2 ──────────────────────────────────────────────────────────

  describe "snapshot_for/2" do
    test "empty content returns empty rows" do
      assert Core.snapshot_for(%{}, 0) == %{"rows" => [], "sv" => 2}
    end

    test "missing tab index returns empty rows" do
      content = %{"tabs" => [%{"cells" => %{"A1" => %{"v" => "hello"}}}]}
      assert Core.snapshot_for(content, 5) == %{"rows" => [], "sv" => 2}
    end

    test "basic value cell appears in the dense grid" do
      content = %{"tabs" => [%{"cells" => %{"A1" => %{"v" => "hello"}}}]}
      assert Core.snapshot_for(content) == %{"rows" => [["hello"]], "sv" => 2}
    end

    test "numeric and boolean values are stringified correctly" do
      cells = %{
        "A1" => %{"v" => 42},
        "B1" => %{"v" => 3.14},
        "A2" => %{"v" => true},
        "B2" => %{"v" => false}
      }

      content = %{"tabs" => [%{"cells" => cells}]}
      snapshot = Core.snapshot_for(content)
      rows = snapshot["rows"]

      assert Enum.at(rows, 0) == ["42", "3.14"]
      assert Enum.at(rows, 1) == ["TRUE", "FALSE"]
    end

    test "frozen_rows=1 separates head from body" do
      cells = %{
        "A1" => %{"v" => "Name"},
        "B1" => %{"v" => "Score"},
        "A2" => %{"v" => "Alice"},
        "B2" => %{"v" => "99"}
      }

      content = %{"tabs" => [%{"cells" => cells, "frozen_rows" => 1}]}
      snapshot = Core.snapshot_for(content)

      assert snapshot["head"] == ["Name", "Score"]
      assert snapshot["rows"] == [["Alice", "99"]]
    end

    test "malformed cell addresses are skipped gracefully" do
      cells = %{
        "A1" => %{"v" => "good"},
        "BADADDR" => %{"v" => "ignored"},
        "1Z" => %{"v" => "also ignored"}
      }

      content = %{"tabs" => [%{"cells" => cells}]}
      snapshot = Core.snapshot_for(content)
      assert snapshot == %{"rows" => [["good"]], "sv" => 2}
    end

    test "every snapshot_for/2 result carries the schema-version stamp (sv)" do
      sv = Core.snapshot_schema_version()

      cases = [
        Core.snapshot_for(%{}, 0),
        Core.snapshot_for(%{"tabs" => [%{"cells" => %{}}]}, 0),
        Core.snapshot_for(%{"tabs" => [%{"cells" => %{"A1" => %{"v" => "x"}}}]}, 0),
        Core.snapshot_for(%{"tabs" => [%{"cells" => %{"A1" => %{"v" => "x"}}}]}, 9)
      ]

      for snap <- cases do
        assert snap["sv"] == sv
      end
    end

    test "a tab past the position cap is truncated, marked, and reports the true row count" do
      # 10 columns × 30_000 rows = 300_000 positions > the 200_000 cap. Columns
      # clamp first (10 ≤ cap), then rows truncate to div(200_000, 10) = 20_000.
      cells =
        for r <- 1..30_000, into: %{} do
          {"A#{r}", %{"v" => r}}
        end
        |> Map.merge(%{"J1" => %{"v" => "wide"}})

      snapshot = Core.snapshot_for(%{"tabs" => [%{"cells" => cells}]})

      assert length(snapshot["rows"]) == 20_000
      assert snapshot["truncated"] == true
      assert snapshot["total_rows"] == 30_000
    end

    test "a small tab carries no truncation marker" do
      content = %{"tabs" => [%{"cells" => %{"A1" => %{"v" => "x"}, "B2" => %{"v" => "y"}}}]}
      snapshot = Core.snapshot_for(content)

      refute Map.has_key?(snapshot, "truncated")
      refute Map.has_key?(snapshot, "total_rows")
    end
  end

  # ── snapshot_for/2 conditional-formatting projection (CF-A) ─────────────────

  describe "snapshot_for/2 conditional formatting" do
    test "a CF-only cell (no manual style) earns a styles entry" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{"A1" => %{"v" => 150}},
            "cond_formats" => [cf_rule("A1", "gt", 100, %{"bg" => "#ff0000"})]
          }
        ]
      }

      snapshot = Core.snapshot_for(content)
      assert snapshot["styles"] == %{"0,0" => %{"bg" => "#ff0000"}}
    end

    test "a rule that does not fire on its cell contributes no styling" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{"A1" => %{"v" => 50}},
            "cond_formats" => [cf_rule("A1", "gt", 100, %{"bg" => "#ff0000"})]
          }
        ]
      }

      snapshot = Core.snapshot_for(content)
      refute Map.has_key?(snapshot, "styles")
    end

    test "CF composes per-key with a manual style (CF bg wins, manual al/b survive)" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{
              "A1" => %{"v" => 150, "s" => %{"al" => "center", "b" => true, "bg" => "#000000"}}
            },
            "cond_formats" => [cf_rule("A1", "gt", 100, %{"bg" => "#ff0000"})]
          }
        ]
      }

      snapshot = Core.snapshot_for(content)
      assert snapshot["styles"]["0,0"] == %{"al" => "center", "b" => true, "bg" => "#ff0000"}
    end

    test "a frozen head row gets NO conditional formatting" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{"A1" => %{"v" => 150}, "A2" => %{"v" => 150}},
            "frozen_rows" => 1,
            "cond_formats" => [cf_rule("A1:A2", "gt", 100, %{"bg" => "#ff0000"})]
          }
        ]
      }

      snapshot = Core.snapshot_for(content)
      # only the body cell A2 (body row 0) carries CF; the head cell A1 is dropped
      assert snapshot["styles"] == %{"0,0" => %{"bg" => "#ff0000"}}
    end

    test "a rule whose range never meets an occupied cell contributes nothing" do
      content = %{
        "tabs" => [
          %{
            "cells" => %{"A1" => %{"v" => 150}},
            "cond_formats" => [cf_rule("Z90:Z100", "gt", 0, %{"bg" => "#ff0000"})]
          }
        ]
      }

      snapshot = Core.snapshot_for(content)
      refute Map.has_key?(snapshot, "styles")
    end

    test "malformed cond_formats leaves the snapshot byte-identical to no rules" do
      cells = %{"A1" => %{"v" => "hello"}, "B2" => %{"v" => 3}}
      base = Core.snapshot_for(%{"tabs" => [%{"cells" => cells}]})

      garbage = Core.snapshot_for(%{"tabs" => [%{"cells" => cells, "cond_formats" => "garbage"}]})
      assert garbage == base

      bad_rules =
        Core.snapshot_for(%{
          "tabs" => [
            %{
              "cells" => cells,
              "cond_formats" => [
                %{
                  "range" => "notaref",
                  "when" => %{"op" => "gt", "value" => 1},
                  "style" => %{"bg" => "#ff0000"}
                },
                %{"range" => "A1", "when" => %{"op" => "bogus"}, "style" => %{"bg" => "#ff0000"}},
                "junk"
              ]
            }
          ]
        })

      assert bad_rules == base
    end

    test "contains evaluates over the fmt DISPLAY string the snapshot itself renders (CF-D5)" do
      # The projection must hand the FULL raw cell (fmt included) to the
      # kernel: a percent 0.25 renders "25.00%", and the rule matches THAT
      # string — never the raw "0.25".
      cells = %{"A1" => %{"v" => 0.25, "fmt" => "percent"}}

      display_rule = [cf_rule("A1", "contains", "25.00%", %{"bg" => "#ffee00"})]

      snapshot =
        Core.snapshot_for(%{"tabs" => [%{"cells" => cells, "cond_formats" => display_rule}]})

      assert snapshot["rows"] == [["25.00%"]]
      assert snapshot["styles"] == %{"0,0" => %{"bg" => "#ffee00"}}

      raw_rule = [cf_rule("A1", "contains", "0.25", %{"bg" => "#ffee00"})]
      raw = Core.snapshot_for(%{"tabs" => [%{"cells" => cells, "cond_formats" => raw_rule}]})
      refute Map.has_key?(raw, "styles")
    end

    test "an empty cond_formats list leaves the snapshot untouched" do
      cells = %{"A1" => %{"v" => "x", "s" => %{"b" => true}}}
      base = Core.snapshot_for(%{"tabs" => [%{"cells" => cells}]})
      with_empty = Core.snapshot_for(%{"tabs" => [%{"cells" => cells, "cond_formats" => []}]})
      assert with_empty == base
      assert with_empty["styles"] == %{"0,0" => %{"b" => true}}
    end

    test "manual-style bg sanitizes case-insensitively and rejects a trailing newline" do
      # Manual `"s".bg` routes through the single `CondFormat.sanitize_bg/1`
      # owner: uppercase normalizes to lowercase; a trailing-newline stowaway
      # (`\z`-anchored now) is dropped rather than stored.
      cells = %{
        "A1" => %{"v" => "x", "s" => %{"bg" => "#FF00AA"}},
        "A2" => %{"v" => "y", "s" => %{"bg" => "#ff0000\n"}}
      }

      snapshot = Core.snapshot_for(%{"tabs" => [%{"cells" => cells}]})
      assert snapshot["styles"]["0,0"] == %{"bg" => "#ff00aa"}
      # A2's newline bg was dropped; no other style keys → no entry at all.
      refute Map.has_key?(snapshot["styles"], "1,0")
    end
  end

  # ── Engine.recompute/1 tokenizer overflow ───────────────────────────────────

  describe "Engine.recompute/1 with an out-of-range float literal" do
    test "a numeric literal overflowing float range degrades to #REF! instead of raising" do
      # 10^320 overflows the float range; String.to_float raises ArgumentError.
      # lex_number must fail closed so parse_formula returns :invalid → #REF!.
      formula = "=1" <> String.duplicate("0", 320) <> ".0"
      content = %{"tabs" => [%{"cells" => %{"A1" => %{"f" => formula}}}]}

      recomputed = Engine.recompute(content)
      cell = get_in(recomputed, ["tabs", Access.at(0), "cells", "A1"])

      assert cell["v"] == "#REF!"
      assert cell["t"] == "e"
    end
  end

  # ── get_tab/2 ───────────────────────────────────────────────────────────────

  describe "get_tab/2" do
    test "returns the tab at the given 0-based index" do
      tab0 = %{"cells" => %{}}
      tab1 = %{"cells" => %{"A1" => %{"v" => "x"}}}
      content = %{"tabs" => [tab0, tab1]}
      assert Core.get_tab(content, 0) == tab0
      assert Core.get_tab(content, 1) == tab1
    end

    test "out-of-range index returns nil" do
      content = %{"tabs" => [%{"cells" => %{}}]}
      assert Core.get_tab(content, 5) == nil
    end

    test "content without tabs key returns nil" do
      assert Core.get_tab(%{}, 0) == nil
      assert Core.get_tab(nil, 0) == nil
    end
  end
end
