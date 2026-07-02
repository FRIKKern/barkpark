defmodule Barkpark.Search.SurfaceConfigTest do
  use ExUnit.Case, async: true

  alias Barkpark.Search.SurfaceConfig
  alias Barkpark.Search.SurfaceConfigs

  test "struct has correct defaults for optional fields" do
    config = %SurfaceConfig{}
    assert config.searchable_fields == []
    assert config.typo_policy == %{}
    assert config.zero_hit_strategy == "drop_tokens"
    assert config.highlight_fields == []
  end

  test "struct surface and scope default to nil" do
    config = %SurfaceConfig{}
    assert is_nil(config.surface)
    assert is_nil(config.scope)
  end

  test "struct can be built with explicit field values" do
    config = %SurfaceConfig{
      surface: "documents",
      scope: "production",
      searchable_fields: [%{"field" => "title", "weight" => 2}],
      highlight_fields: ["title", "body"],
      zero_hit_strategy: "fallback"
    }

    assert config.surface == "documents"
    assert config.scope == "production"
    assert config.searchable_fields == [%{"field" => "title", "weight" => 2}]
    assert config.highlight_fields == ["title", "body"]
    assert config.zero_hit_strategy == "fallback"
  end

  test "schema table name is search_surface_config" do
    assert SurfaceConfig.__schema__(:source) == "search_surface_config"
  end

  test "schema field types match expectations" do
    assert SurfaceConfig.__schema__(:type, :surface) == :string
    assert SurfaceConfig.__schema__(:type, :scope) == :string
    assert SurfaceConfig.__schema__(:type, :zero_hit_strategy) == :string
    assert SurfaceConfig.__schema__(:type, :highlight_fields) == {:array, :string}
  end

  # ── ETS TTL cache mechanics (no DB: stubbed via __store_config_for_test__) ──
  describe "get/2 cache" do
    setup do
      SurfaceConfigs.__reset_cache_for_test__()
      :ok
    end

    test "a fresh cache entry is served verbatim without hitting the loader" do
      config = %{"searchable_fields" => [%{"path" => "title", "weight" => 7}]}
      SurfaceConfigs.__store_config_for_test__("documents", "ds-fresh", config)

      # A DB round-trip in this async, non-DataCase test would raise; a plain
      # cache hit returns the stored map byte-for-byte.
      assert SurfaceConfigs.get("documents", "ds-fresh") == config
    end

    test "clear-on-full bounds the table at @max_cached_configs (512)" do
      for i <- 1..512 do
        SurfaceConfigs.__store_config_for_test__("documents", "ds#{i}", %{"i" => i})
      end

      assert SurfaceConfigs.__cache_size_for_test__() == 512

      # The 513th insert clears the table first, then inserts the new entry.
      SurfaceConfigs.__store_config_for_test__("documents", "ds513", %{"i" => 513})
      assert SurfaceConfigs.__cache_size_for_test__() == 1
    end

    test "distinct {surface, scope} keys don't collide" do
      SurfaceConfigs.__store_config_for_test__("documents", "prod", %{"who" => "docs"})
      SurfaceConfigs.__store_config_for_test__("media", "prod", %{"who" => "media"})

      assert SurfaceConfigs.get("documents", "prod") == %{"who" => "docs"}
      assert SurfaceConfigs.get("media", "prod") == %{"who" => "media"}
    end
  end
end
