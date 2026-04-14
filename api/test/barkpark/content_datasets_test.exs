defmodule Barkpark.ContentDatasetsTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  test "list_datasets returns sorted distinct values from schema_definitions and documents" do
    {:ok, _} = Content.upsert_schema(%{"name" => "post", "title" => "P", "visibility" => "public", "fields" => []}, "alpha")
    {:ok, _} = Content.upsert_schema(%{"name" => "post", "title" => "P", "visibility" => "public", "fields" => []}, "beta")
    {:ok, _} = Content.create_document("post", %{"_id" => "d1", "title" => "x"}, "gamma")

    datasets = Content.list_datasets()
    assert "alpha" in datasets
    assert "beta" in datasets
    assert "gamma" in datasets
    assert datasets == Enum.sort(datasets)
  end

  test "list_datasets always includes production even on an empty dataset table" do
    datasets = Content.list_datasets()
    assert "production" in datasets
  end
end
