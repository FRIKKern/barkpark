defmodule Barkpark.Media.Delivery.SearchEscapeTest do
  use ExUnit.Case, async: true

  alias Barkpark.Media.Delivery.Search

  describe "mime_pattern/1" do
    test "escapes the LIKE underscore wildcard" do
      assert Search.mime_pattern("image_png") == "image\\_png%"
    end

    test "escapes the LIKE percent wildcard" do
      assert Search.mime_pattern("a%b") == "a\\%b%"
    end

    test "escapes the backslash first" do
      assert Search.mime_pattern("c\\d") == "c\\\\d%"
    end
  end
end
