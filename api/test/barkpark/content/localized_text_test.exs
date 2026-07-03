defmodule Barkpark.Content.LocalizedTextTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.LocalizedText

  describe "resolve/2 — fallback chain" do
    test "primary language present → returns primary" do
      assert {:ok, "nob", "Hei"} =
               LocalizedText.resolve(
                 %{"nob" => "Hei", "eng" => "Hello"},
                 ["nob", "eng", "first-non-empty"]
               )
    end

    test "primary missing, secondary used → returns secondary" do
      assert {:ok, "eng", "Hello"} =
               LocalizedText.resolve(
                 %{"eng" => "Hello"},
                 ["nob", "eng", "first-non-empty"]
               )
    end

    test "primary missing + secondary missing → first-non-empty scoops it up" do
      assert {:ok, "deu", "Hallo"} =
               LocalizedText.resolve(
                 %{"deu" => "Hallo"},
                 ["nob", "eng", "first-non-empty"]
               )
    end

    test "all languages empty → :no_value" do
      assert {:error, :no_value} =
               LocalizedText.resolve(
                 %{"nob" => "", "eng" => "  ", "deu" => ""},
                 ["nob", "eng", "first-non-empty"]
               )
    end

    test "empty value map → :no_value" do
      assert {:error, :no_value} = LocalizedText.resolve(%{}, ["nob", "eng", "first-non-empty"])
    end

    test "empty primary string is treated as missing" do
      assert {:ok, "eng", "Hello"} =
               LocalizedText.resolve(
                 %{"nob" => "", "eng" => "Hello"},
                 ["nob", "eng"]
               )
    end

    test "whitespace-only is treated as missing" do
      assert {:ok, "eng", "Hello"} =
               LocalizedText.resolve(
                 %{"nob" => "   \n\t", "eng" => "Hello"},
                 ["nob", "eng"]
               )
    end

    test "no fallback sentinel + no chain match → :no_value even if other langs filled" do
      assert {:error, :no_value} = LocalizedText.resolve(%{"deu" => "Hallo"}, ["nob", "eng"])
    end

    test "first-non-empty is DETERMINISTIC — lowest language key wins, stably" do
      # Several non-empty languages, only the sentinel to resolve them: the pick
      # must be the alphabetically-smallest key ("aaa"), not a map-hash-order
      # accident — and it must not change across insertion orders.
      map_a = %{"zul" => "Z", "aaa" => "A", "mmm" => "M"}
      map_b = %{"mmm" => "M", "aaa" => "A", "zul" => "Z"}

      assert {:ok, "aaa", "A"} = LocalizedText.resolve(map_a, ["first-non-empty"])
      assert {:ok, "aaa", "A"} = LocalizedText.resolve(map_b, ["first-non-empty"])

      # Same map, many runs → identical winner every time.
      for _ <- 1..50 do
        assert {:ok, "aaa", "A"} = LocalizedText.resolve(map_a, ["first-non-empty"])
      end
    end

    test "first-non-empty skips empties in sorted order" do
      # "aaa" sorts first but is blank → the next non-empty sorted key wins.
      assert {:ok, "bbb", "B"} =
               LocalizedText.resolve(
                 %{"aaa" => "  ", "ccc" => "C", "bbb" => "B"},
                 ["first-non-empty"]
               )
    end
  end

  describe "primary_language/1" do
    test "first explicit language wins" do
      assert "nob" = LocalizedText.primary_language(["nob", "eng", "first-non-empty"])
    end

    test "skips first-non-empty sentinel" do
      assert "eng" = LocalizedText.primary_language(["first-non-empty", "eng"])
    end

    test "empty chain → nil" do
      assert is_nil(LocalizedText.primary_language([]))
    end

    test "sentinel-only chain → nil" do
      assert is_nil(LocalizedText.primary_language(["first-non-empty"]))
    end
  end

  describe "non_empty?/1" do
    test "non-empty string → true" do
      assert LocalizedText.non_empty?("Hei")
    end

    test "empty string → false" do
      refute LocalizedText.non_empty?("")
    end

    test "whitespace → false" do
      refute LocalizedText.non_empty?("   ")
    end

    test "nil → false" do
      refute LocalizedText.non_empty?(nil)
    end
  end
end
