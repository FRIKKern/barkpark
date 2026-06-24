defmodule Barkpark.Search.SurfaceConfigTest do
  use ExUnit.Case, async: true

  alias Barkpark.Search.SurfaceConfig

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
end
