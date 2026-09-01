defmodule Barkpark.Search.SanitizerTest do
  use ExUnit.Case, async: true

  alias Barkpark.Search.Sanitizer

  test "accepts and normalizes valid queries" do
    assert {:ok, "hero banner"} = Sanitizer.sanitize("  Hero   Banner  ")
  end

  test "rejects empty and too-short queries" do
    assert {:reject, :empty} = Sanitizer.sanitize("   ")
    assert {:reject, :too_short} = Sanitizer.sanitize("a")
  end

  test "rejects profanity without storing it" do
    assert {:reject, :profanity} = Sanitizer.sanitize("what the fuck")
  end

  test "rejects genuine junk (repeated chars, punctuation-only)" do
    assert {:reject, :spam} = Sanitizer.sanitize(";;;;;;;")
    assert {:reject, :spam} = Sanitizer.sanitize("!!!???")
    assert {:reject, :spam} = Sanitizer.sanitize("aaaaaaaa")
  end

  test "accepts ordinary English that happens to contain SQL keywords" do
    for q <- [
          "union station",
          "drop shipping",
          "select committee",
          "update manual",
          "delete scene",
          "insert coin"
        ] do
      result = Sanitizer.sanitize(q)

      assert match?({:ok, _}, result),
             "expected #{inspect(q)} to be accepted, got #{inspect(result)}"
    end
  end

  test "accepts non-Latin scripts (CJK, Cyrillic, Arabic)" do
    assert {:ok, _} = Sanitizer.sanitize("日本語")
    assert {:ok, _} = Sanitizer.sanitize("привет")
    assert {:ok, _} = Sanitizer.sanitize("مرحبا")
  end

  test "rejects configured exclude patterns" do
    assert {:reject, :excluded} = Sanitizer.sanitize("test")
    assert {:reject, :excluded} = Sanitizer.sanitize("QWERTY")
  end

  test "rejects invalid-UTF-8 binaries without raising" do
    assert {:reject, :invalid} = Sanitizer.sanitize(<<0xFF, 0xFE>>)
    assert {:reject, :invalid} = Sanitizer.suggest_sanitize(<<0xFF, 0xFE>>)
  end

  test "rejects non-binary input (?q[]= list / ?q[k]= map) without raising" do
    assert {:reject, :invalid} = Sanitizer.sanitize(["x"], [])
    assert {:reject, :invalid} = Sanitizer.sanitize(%{}, [])
  end

  test "suggest gate requires four letters" do
    assert {:reject, :too_short} = Sanitizer.suggest_sanitize("abc")
    assert {:ok, "abcd"} = Sanitizer.suggest_sanitize("abcd")
  end
end
