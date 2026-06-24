defmodule Barkpark.Plugins.Sheets.FmtTest do
  @moduledoc """
  Unit locks for `Barkpark.Plugins.Sheets.Fmt` — the fmt hint vocabulary
  and bidirectional xlsx numFmtId mapping.  Pure functions, no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Fmt

  # ── vocabulary/0 ────────────────────────────────────────────────────────────

  describe "vocabulary/0" do
    test "returns exactly the six documented fmt classes, sorted" do
      assert Fmt.vocabulary() == ["currency", "date", "datetime", "fixed", "percent", "thousands"]
    end
  end

  # ── num_format/1 ────────────────────────────────────────────────────────────

  describe "num_format/1" do
    test "each class maps to its canonical format string" do
      assert Fmt.num_format("fixed") == "0.00"
      assert Fmt.num_format("percent") == "0.00%"
      assert Fmt.num_format("currency") == "$#,##0.00"
      assert Fmt.num_format("thousands") == "#,##0"
      assert Fmt.num_format("date") == "yyyy-mm-dd"
      assert Fmt.num_format("datetime") == "yyyy-mm-dd h:mm:ss"
    end

    test "unknown / nil class returns nil" do
      assert Fmt.num_format("general") == nil
      assert Fmt.num_format(nil) == nil
      assert Fmt.num_format("bogus") == nil
    end
  end

  # ── classify/2 ──────────────────────────────────────────────────────────────

  describe "classify/2" do
    test "nil id returns nil regardless of custom map" do
      assert Fmt.classify(nil, %{}) == nil
      assert Fmt.classify(nil, %{"1" => "0.00"}) == nil
    end

    test "builtin numeric ids map to the expected class" do
      assert Fmt.classify(1, %{}) == "fixed"
      assert Fmt.classify(2, %{}) == "fixed"
      assert Fmt.classify(3, %{}) == "thousands"
      assert Fmt.classify(9, %{}) == "percent"
      assert Fmt.classify(10, %{}) == "percent"
      assert Fmt.classify(14, %{}) == "date"
      assert Fmt.classify(22, %{}) == "datetime"
      assert Fmt.classify(44, %{}) == "currency"
    end

    test "id 0 (general) and other unregistered builtins return nil" do
      assert Fmt.classify(0, %{}) == nil
      assert Fmt.classify(11, %{}) == nil
      assert Fmt.classify(48, %{}) == nil
    end

    test "string id is parsed and delegated correctly" do
      assert Fmt.classify("9", %{}) == "percent"
      assert Fmt.classify("14", %{}) == "date"
      assert Fmt.classify("0", %{}) == nil
    end

    test "non-numeric string id returns nil" do
      assert Fmt.classify("abc", %{}) == nil
      assert Fmt.classify("", %{}) == nil
    end

    test "custom id (>= 164) falls back to classify_format via the custom map" do
      assert Fmt.classify(164, %{"164" => "0.00%"}) == "percent"
      assert Fmt.classify(165, %{"165" => "$#,##0.00"}) == "currency"
      assert Fmt.classify(200, %{"200" => "yyyy-mm-dd"}) == "date"
      assert Fmt.classify(164, %{"164" => "General"}) == nil
      assert Fmt.classify(164, %{}) == nil
    end
  end

  # ── classify_format/1 ───────────────────────────────────────────────────────

  describe "classify_format/1" do
    test "percent wins when bare format contains %" do
      assert Fmt.classify_format("0.00%") == "percent"
      assert Fmt.classify_format("0%") == "percent"
    end

    test "currency detected via common symbols ($ € £ ¥ kr)" do
      assert Fmt.classify_format("$#,##0.00") == "currency"
      assert Fmt.classify_format("€#,##0.00") == "currency"
      assert Fmt.classify_format("£#,##0") == "currency"
      assert Fmt.classify_format("¥#,##0") == "currency"
      assert Fmt.classify_format("kr #,##0.00") == "currency"
    end

    test "currency symbol inside [$…] bracket section is detected" do
      assert Fmt.classify_format("[$kr-414] #,##0.00") == "currency"
    end

    test "bracket color prefix [Red] does not misclassify as date; 0.00 still → fixed" do
      assert Fmt.classify_format("[Red]0.00") == "fixed"
    end

    test "date format with y and d → date; with h as well → datetime" do
      assert Fmt.classify_format("yyyy-mm-dd") == "date"
      assert Fmt.classify_format("yyyy-mm-dd h:mm:ss") == "datetime"
      assert Fmt.classify_format("d/m/yy") == "date"
    end

    test "time-only (h but no y/d) → datetime (model has no time-only type)" do
      assert Fmt.classify_format("hh:mm") == "datetime"
      assert Fmt.classify_format("h:mm:ss") == "datetime"
    end

    test "thousands detected via #,## pattern" do
      assert Fmt.classify_format("#,##0") == "thousands"
      assert Fmt.classify_format("#,##0;[Red]-#,##0") == "thousands"
    end

    test "fixed detected via 0.0 pattern" do
      assert Fmt.classify_format("0.0") == "fixed"
      assert Fmt.classify_format("0.000") == "fixed"
    end

    test "unrecognised format string returns nil" do
      assert Fmt.classify_format("General") == nil
      assert Fmt.classify_format("@") == nil
      assert Fmt.classify_format("0") == nil
    end

    test "non-string inputs return nil" do
      assert Fmt.classify_format(nil) == nil
      assert Fmt.classify_format(42) == nil
      assert Fmt.classify_format(%{}) == nil
    end

    test "every canonical export format round-trips to its own class" do
      for fmt <- Fmt.vocabulary() do
        assert fmt |> Fmt.num_format() |> Fmt.classify_format() == fmt,
               "canonical round-trip failed for #{fmt}"
      end
    end
  end
end
