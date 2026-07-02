defmodule Barkpark.Plugins.Sheets.FmtTest do
  @moduledoc """
  Unit locks for `Barkpark.Plugins.Sheets.Fmt` — the fmt hint vocabulary
  and bidirectional xlsx numFmtId mapping.  Pure functions, no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.{Core, Fmt}

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

  # ── display/2 ─────────────────────────────────────────────────────────────
  #
  # PARITY CONTRACT — the web TS twin copies this vector table VERBATIM. Every
  # row is {value, fmt, expected display}. Number classes use ties-away-from-
  # zero (Kernel.round/1, Excel half-up); dates parse ISO-8601 xlsx values.

  describe "display/2" do
    @vectors [
      # percent — canonical 0.00%, no grouping, value * 100
      {0.25, "percent", "25.00%"},
      {0.125, "percent", "12.50%"},
      {-0.5, "percent", "-50.00%"},
      {1, "percent", "100.00%"},
      # thousands — round to integer, comma-group every 3 digits
      {1200, "thousands", "1,200"},
      {-1234.5, "thousands", "-1,235"},
      {999, "thousands", "999"},
      {1_000_000, "thousands", "1,000,000"},
      # fixed — 2 decimals, NO grouping
      {3.5, "fixed", "3.50"},
      {1234.5, "fixed", "1234.50"},
      {-0.001, "fixed", "0.00"},
      # currency — sign OUTSIDE the $, grouped, 2 decimals
      {1234.5, "currency", "$1,234.50"},
      {-2, "currency", "-$2.00"},
      {0, "currency", "$0.00"},
      # date / datetime — ISO-8601 strings from xlsx import
      {"2026-06-12", "date", "2026-06-12"},
      {"2026-06-12T09:30:00", "date", "2026-06-12"},
      {"2026-06-12T09:30:00", "datetime", "2026-06-12 09:30:00"},
      {"2026-06-12T09:30:00.123", "datetime", "2026-06-12 09:30:00"},
      # unparseable date value returns verbatim (never raises)
      {"not-a-date", "date", "not-a-date"},
      # booleans render TRUE/FALSE regardless of fmt
      {true, "percent", "TRUE"},
      {false, "currency", "FALSE"},
      # non-date fmt on a string returns the string
      {"hello", "percent", "hello"},
      {"world", "currency", "world"},
      # general path (nil fmt): numbers via number_to_display, binaries verbatim
      {1200, nil, "1200"},
      {3.5, nil, "3.5"},
      {1_000_000.0, nil, "1000000"},
      {"text", nil, "text"},
      {true, nil, "TRUE"},
      # class/type mismatch falls back to the general path
      {45_000, "date", "45000"}
    ]

    for {value, fmt, expected} <- @vectors do
      test "display(#{inspect(value)}, #{inspect(fmt)}) == #{inspect(expected)}" do
        assert Fmt.display(unquote(Macro.escape(value)), unquote(fmt)) == unquote(expected)
      end
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

  # ── cross-runtime display parity ────────────────────────────────────────────
  #
  # The web raw document view ships its own `formatDisplay`/`numberToDisplay`
  # twins (web/lib/sheets.ts). This block and the node suite
  # (web/__tests__/sheets-display.test.ts) read the SAME fixture, so a drift on
  # either runtime reds a gate here. The fixture is generated by running these
  # very functions; this side is the regression lock (and proves the path
  # resolves), the node side catches TS divergence.

  describe "web display parity fixture" do
    @fixture_path Path.expand(
                    "../../../../../web/__tests__/fixtures/fmt-display-parity.json",
                    __DIR__
                  )

    test "Fmt.display matches every fixture row (Core.number_to_display for fmt-less numbers)" do
      rows = @fixture_path |> File.read!() |> Jason.decode!()
      assert rows != [], "parity fixture must not be empty"

      for %{"v" => v, "fmt" => fmt, "out" => out} <- rows do
        assert Fmt.display(v, fmt) == out,
               "Fmt.display(#{inspect(v)}, #{inspect(fmt)}) => #{inspect(Fmt.display(v, fmt))}, expected #{inspect(out)}"

        if is_nil(fmt) and is_number(v) do
          assert Core.number_to_display(v) == out
        end
      end
    end
  end
end
