defmodule Barkpark.ContentDatasetsTest do
  use Barkpark.DataCase, async: true
  alias Barkpark.Content

  test "list_datasets returns sorted distinct values from schema_definitions and documents" do
    # W2: schemas are PROJECT-scoped (one catalog per project) after the
    # uniqueness flip to (name, project_id). Two schemas sharing a name under the
    # same Default project now COLLAPSE into one row — so use DISTINCT names to
    # cover the alpha/beta dataset strings (the `dataset` STRING mirror is what
    # list_datasets reads).
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post_alpha", "title" => "P", "visibility" => "public", "fields" => []},
        "alpha"
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post_beta", "title" => "P", "visibility" => "public", "fields" => []},
        "beta"
      )

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
