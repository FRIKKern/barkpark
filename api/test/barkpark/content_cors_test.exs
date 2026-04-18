defmodule Barkpark.ContentCorsTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content

  test "allowed_origins_for_dataset/1 returns [] when no schemas exist" do
    assert Content.allowed_origins_for_dataset("ds_empty_nonexistent") == []
  end

  test "returns union across multiple schemas, deduplicated" do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "cors_origins" => ["https://a.example", "https://shared.example"]},
        "ds_union_test"
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "page", "title" => "Page", "cors_origins" => ["https://b.example", "https://shared.example"]},
        "ds_union_test"
      )

    origins = Content.allowed_origins_for_dataset("ds_union_test")

    assert Enum.sort(origins) ==
             Enum.sort(["https://a.example", "https://b.example", "https://shared.example"])
  end

  test "returns [] when all schemas have empty cors_origins" do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post"},
        "ds_default"
      )

    assert Content.allowed_origins_for_dataset("ds_default") == []
  end

  test "wildcard is preserved in the returned list" do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "cors_origins" => ["*"]},
        "ds_wildcard"
      )

    assert Content.allowed_origins_for_dataset("ds_wildcard") == ["*"]
  end
end
