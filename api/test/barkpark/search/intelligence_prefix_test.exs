defmodule Barkpark.Search.IntelligencePrefixTest do
  use ExUnit.Case, async: true

  alias Barkpark.Search.Intelligence

  describe "escape_like_prefix/1" do
    test "escapes ILIKE metacharacters, backslash first" do
      assert Intelligence.escape_like_prefix("a%b_c\\") == "a\\%b\\_c\\\\"
    end

    test "passes a plain prefix through unchanged" do
      assert Intelligence.escape_like_prefix("hello world") == "hello world"
    end
  end
end
