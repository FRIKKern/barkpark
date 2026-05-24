defmodule Barkpark.Media.SearchQuerySanitizerTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media.SearchQuerySanitizer

  test "accepts and normalizes valid queries" do
    assert {:ok, "hero banner"} = SearchQuerySanitizer.sanitize("  Hero   Banner  ")
  end

  test "rejects empty and too-short queries" do
    assert {:reject, :empty} = SearchQuerySanitizer.sanitize("   ")
    assert {:reject, :too_short} = SearchQuerySanitizer.sanitize("a")
  end

  test "rejects profanity without storing it" do
    assert {:reject, :profanity} = SearchQuerySanitizer.sanitize("what the fuck")
  end

  test "rejects spam patterns" do
    assert {:reject, :spam} = SearchQuerySanitizer.sanitize(";;;;;;;")
    assert {:reject, :spam} = SearchQuerySanitizer.sanitize("drop table users")
  end
end
