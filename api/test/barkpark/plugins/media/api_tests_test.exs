defmodule Barkpark.Plugins.Media.ApiTestsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Media
  alias Barkpark.Plugins.Media.ApiTests

  @allowed_methods [:get, :post, :put, :patch, :delete]

  setup_all do
    specs = Media.api_tests()
    {:ok, specs: specs}
  end

  describe "Media.api_tests/0" do
    test "returns at least 8 specs", %{specs: specs} do
      assert length(specs) >= 8
    end

    test "matches ApiTests.specs/0", %{specs: specs} do
      assert specs == ApiTests.specs()
    end

    test "every spec has required keys", %{specs: specs} do
      for spec <- specs do
        assert Map.has_key?(spec, :name)
        assert Map.has_key?(spec, :method)
        assert Map.has_key?(spec, :path)
        assert Map.has_key?(spec, :asserts)
        assert spec.method in @allowed_methods
        assert String.starts_with?(spec.path, "/")
        assert length(spec.asserts) > 0
      end
    end

    test "mutating specs declare cleanup", %{specs: specs} do
      mutating =
        Enum.filter(specs, fn spec ->
          spec.method in [:post, :put, :patch, :delete] and
            String.contains?(spec.path, "mutate")
        end)

      assert mutating != []

      for spec <- mutating do
        assert is_list(spec.cleanup)
        assert length(spec.cleanup) >= 1
      end
    end

    test "covers search, collections, schemas, studio, and auth negative", %{specs: specs} do
      paths = Enum.map(specs, & &1.path)

      assert Enum.any?(paths, &String.contains?(&1, "/search"))
      assert Enum.any?(paths, &String.contains?(&1, "/collections"))
      assert Enum.any?(paths, &String.contains?(&1, "/v1/schemas/production"))
      assert Enum.any?(paths, &String.contains?(&1, "/studio/production/media"))

      auth_negative =
        Enum.filter(specs, fn spec ->
          Map.get(spec, :auth, :none) == :none and spec.method in [:post, :delete]
        end)

      assert Enum.any?(auth_negative, &String.contains?(&1.path, "checkout"))
    end
  end
end
