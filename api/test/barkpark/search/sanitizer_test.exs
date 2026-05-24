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

  test "rejects spam patterns" do
    assert {:reject, :spam} = Sanitizer.sanitize(";;;;;;;")
    assert {:reject, :spam} = Sanitizer.sanitize("drop table users")
  end
end
