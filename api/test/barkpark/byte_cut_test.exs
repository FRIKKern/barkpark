defmodule Barkpark.ByteCutTest do
  @moduledoc """
  task-fb5274e13f678d29: a byte cut backs off to a grapheme boundary, so it
  never leaves one regional indicator (a boxed letter) or a partial tag flag (a
  plain black flag).
  """
  use ExUnit.Case, async: true

  alias Barkpark.ByteCut

  @scotland "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
  @mark "\u{0301}"

  test "a cut between the two indicators of a flag drops the flag" do
    assert ByteCut.prefix("ab🇳🇴", 6) == "ab"
    assert ByteCut.prefix("ab🇳🇴cd", 9) == "ab"
    assert ByteCut.prefix("ab🇳🇴cd", 10) == "ab🇳🇴"
  end

  test "a cut inside a tag flag drops the whole flag" do
    for max <- 3..(2 + byte_size(@scotland) - 1) do
      assert ByteCut.prefix("ab" <> @scotland <> "!", max) == "ab", "max #{max}"
    end

    assert ByteCut.prefix("ab" <> @scotland <> "!", 2 + byte_size(@scotland)) == "ab" <> @scotland
  end

  test "pairing counts from the start of a run of indicators" do
    # 🇳🇴🇸🇪 is two flags. A cut after the third indicator keeps the first flag only.
    assert ByteCut.prefix("🇳🇴🇸🇪", 12) == "🇳🇴"
    assert ByteCut.prefix("x🇳🇴🇸🇪", 13) == "x🇳🇴"
  end

  test "a combining mark after an ASCII letter belongs to the letter" do
    assert ByteCut.prefix("abc" <> "e" <> @mark <> "z", 4) == "abc"
    assert ByteCut.prefix("abc" <> "e" <> @mark <> "z", 6) == "abce" <> @mark
  end

  test "CR LF is one grapheme" do
    assert ByteCut.prefix("ab\r\ncd", 3) == "ab"
    assert ByteCut.prefix("ab\r\ncd", 4) == "ab\r\n"
  end

  test "a codepoint is never split" do
    assert ByteCut.prefix("aé", 2) == "a"
    assert ByteCut.prefix("a🐕", 4) == "a"
  end

  test "one grapheme larger than the budget keeps its codepoint prefix, unless it is a flag" do
    huge = "x" <> String.duplicate(@mark, 100)
    assert ByteCut.prefix(huge, 7) == "x" <> String.duplicate(@mark, 3)
    assert ByteCut.prefix("🇳🇴", 4) == ""
    assert ByteCut.prefix(@scotland, 10) == ""
  end

  test "short text, an empty budget and bad bytes" do
    assert ByteCut.prefix("abc", 3) == "abc"
    assert ByteCut.prefix("abc", 0) == ""
    assert ByteCut.prefix("abc", -1) == ""
    assert ByteCut.prefix("ab" <> <<0xFF>> <> "cdef", 4) == "ab"
  end

  test "every cut of mixed text ends on a grapheme boundary of the whole text" do
    text =
      "a🇳🇴b" <>
        @scotland <> "e" <> @mark <> "\r\n" <> "👨‍👩‍👧" <> "🇸🇪🇳🇴🇫" <> "z" <> @mark <> @mark <> "ok"

    boundaries = boundaries(text)

    for max <- 0..byte_size(text) do
      cut = ByteCut.prefix(text, max)
      assert byte_size(cut) <= max
      assert byte_size(cut) in boundaries, "max #{max} gave #{inspect(cut)}"
      # The longest such prefix: the next boundary is past the budget.
      next = Enum.find(boundaries, &(&1 > byte_size(cut)))
      assert next == nil or next > max, "max #{max} cut too far back"
    end
  end

  defp boundaries(text) do
    text
    |> String.graphemes()
    |> Enum.scan(0, &(byte_size(&1) + &2))
    |> then(&[0 | &1])
  end
end
