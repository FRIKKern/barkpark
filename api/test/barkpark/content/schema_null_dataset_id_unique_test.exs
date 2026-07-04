defmodule Barkpark.Content.SchemaNullDatasetIdUniqueTest do
  @moduledoc """
  drafts.loop-low-schema-null-dataset-race regression.

  The W2 flip made `(name, dataset_id)` the schema-uniqueness key, but a flat
  deployment (no project resolved) leaves `dataset_id` NULL on every row — and
  Postgres treats each NULL as DISTINCT, so that index gives NULL-dataset rows
  zero protection. Two concurrent `upsert_schema` creates of the same name then
  both miss the read-then-write guard and both insert → duplicate schemas.

  The partial unique index `(name, dataset) WHERE dataset_id IS NULL` backstops
  exactly those rows, keyed on the `dataset` STRING mirror so it does NOT
  conflate two legitimately-distinct datasets.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo

  defp insert_schema(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Repo.insert()
  end

  test "second NULL-dataset_id schema with the same (name, dataset) is rejected, not duplicated" do
    attrs = %{"name" => "post", "title" => "Post", "dataset" => "production", "fields" => []}

    assert {:ok, first} = insert_schema(attrs)
    assert is_nil(first.dataset_id), "flat insert should leave dataset_id NULL"

    # The racing second insert (same name, same dataset string, NULL dataset_id)
    # must map to a changeset error via the partial-index unique_constraint —
    # NOT raise Ecto.ConstraintError, and NOT land a duplicate row.
    assert {:error, changeset} = insert_schema(attrs)
    refute changeset.valid?

    assert Repo.aggregate(
             from(s in SchemaDefinition, where: s.name == "post" and is_nil(s.dataset_id)),
             :count
           ) == 1
  end

  test "same name in DIFFERENT dataset strings (both NULL dataset_id) is allowed" do
    assert {:ok, _} =
             insert_schema(%{
               "name" => "post",
               "title" => "Post",
               "dataset" => "production",
               "fields" => []
             })

    # A distinct dataset string must still coexist — the partial index keys on
    # the `dataset` STRING, so it never globalises the old cross-dataset limit.
    assert {:ok, _} =
             insert_schema(%{
               "name" => "post",
               "title" => "Post (test)",
               "dataset" => "test",
               "fields" => []
             })
  end
end
