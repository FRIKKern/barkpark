defmodule Barkpark.Plugins.Sheets.CoreTest do
  @moduledoc """
  Unit locks for `Barkpark.Plugins.Sheets.Core` — A1 address helpers and
  snapshot synthesis. Pure functions, no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Engine

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
      assert Core.snapshot_for(%{}, 0) == %{"rows" => []}
    end

    test "missing tab index returns empty rows" do
      content = %{"tabs" => [%{"cells" => %{"A1" => %{"v" => "hello"}}}]}
      assert Core.snapshot_for(content, 5) == %{"rows" => []}
    end

    test "basic value cell appears in the dense grid" do
      content = %{"tabs" => [%{"cells" => %{"A1" => %{"v" => "hello"}}}]}
      assert Core.snapshot_for(content) == %{"rows" => [["hello"]]}
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
      assert snapshot == %{"rows" => [["good"]]}
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
