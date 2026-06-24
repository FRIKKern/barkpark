defmodule Barkpark.Search.RetrieverTest do
  @moduledoc """
  Unit tests for Barkpark.Search.Retrievers — the engine-to-module registry
  that backs the Retriever behaviour contract. All functions are pure
  (config-only, no DB), so async: true is safe.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Search.{DocumentsRetriever, Retrievers}

  describe "resolve/1" do
    test "returns DocumentsRetriever for the default postgres engine" do
      assert Retrievers.resolve(%{"engine" => "postgres"}) == DocumentsRetriever
    end

    test "falls back to DocumentsRetriever when engine key is absent" do
      assert Retrievers.resolve(%{}) == DocumentsRetriever
    end

    test "falls back to DocumentsRetriever for an unknown engine (never takes a surface dark)" do
      assert Retrievers.resolve(%{"engine" => "nonexistent_engine_xyz"}) == DocumentsRetriever
    end

    test "falls back to DocumentsRetriever when engine value is nil" do
      assert Retrievers.resolve(%{"engine" => nil}) == DocumentsRetriever
    end
  end

  describe "registry/0" do
    test "always includes the built-in postgres → DocumentsRetriever mapping" do
      registry = Retrievers.registry()
      assert is_map(registry)
      assert Map.get(registry, "postgres") == DocumentsRetriever
    end

    test "registry keys are all strings" do
      registry = Retrievers.registry()
      assert Enum.all?(Map.keys(registry), &is_binary/1)
    end
  end
end
