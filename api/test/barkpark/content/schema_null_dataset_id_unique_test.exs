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

  # 20261005210000: the index is split by owner. Shared rows (workspace_id NULL)
  # keep the one-per-(name, dataset) rule above; each workspace gets its own.
  describe "NULL-dataset_id rows owned by a workspace" do
    setup do
      ws_a = Barkpark.TenancyFixtures.create_workspace!()
      ws_b = Barkpark.TenancyFixtures.create_workspace!()
      %{a: ws_a.id, b: ws_b.id}
    end

    defp owned(ws_id, title) do
      %{
        "name" => "null-ds-owned",
        "title" => title,
        "dataset" => "production",
        "fields" => [],
        "workspace_id" => ws_id
      }
    end

    test "a shared row and two workspaces' rows of the same name coexist", ctx do
      assert {:ok, %{workspace_id: nil}} = insert_schema(owned(nil, "Shared"))
      assert {:ok, %{workspace_id: a}} = insert_schema(owned(ctx.a, "A"))
      assert {:ok, %{workspace_id: b}} = insert_schema(owned(ctx.b, "B"))
      assert {a, b} == {ctx.a, ctx.b}
    end

    test "one workspace cannot hold two", ctx do
      assert {:ok, _} = insert_schema(owned(ctx.a, "A"))
      assert {:error, changeset} = insert_schema(owned(ctx.a, "A again"))
      assert {_, opts} = changeset.errors[:name]
      assert opts[:constraint_name] == "schema_definitions_ws_name_dataset_null_dataset_id_index"
    end
  end
end
