defmodule Barkpark.Content.MutateSchemaReadBudgetTest do
  @moduledoc """
  task-6e2552cdeb223fa2: a mutate batch reads each schema once, however many
  documents it writes.

  Validation (`Writer.do_check_document_schema/4`) and publish
  (`Lifecycle.ensure_no_empty_list_members/4`) passed bare scope keys, so the
  per-request memo never applied and each document re-read its schema and
  re-expanded its named object types: up to three queries per named type, per
  read, per document. The batch now runs under the process memo.

  The measure is the number of `schema_definitions` statements. A batch of 12
  documents must cost exactly what a batch of 2 costs.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, QueryCounter}

  @ds "production"

  setup do
    {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "budget_variant",
          "title" => "Variant",
          "kind" => "object",
          "fields" => [
            %{"name" => "sku", "type" => "string"},
            %{"name" => "price", "type" => "number"}
          ]
        },
        @ds,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "budget_product",
          "title" => "Product",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "variant", "type" => "budget_variant"},
            %{"name" => "variants", "type" => "arrayOf", "of" => %{"type" => "budget_variant"}}
          ]
        },
        @ds,
        scope
      )

    Content.WriteScope.reset_request_memo()
    %{scope: [source: :api] ++ scope}
  end

  defp batch(n, tag) do
    Enum.flat_map(1..n, fn i ->
      id = "budget-#{tag}-#{i}"

      [
        %{
          "createOrReplace" => %{
            "_id" => id,
            "_type" => "budget_product",
            "title" => "Product #{tag} #{i}",
            "variant" => %{"sku" => "S-#{i}", "price" => 10},
            "variants" => [%{"_key" => "k#{i}", "sku" => "S-#{i}", "price" => 10}]
          }
        },
        %{"publish" => %{"id" => id, "type" => "budget_product"}}
      ]
    end)
  end

  defp schema_reads(n, tag, scope) do
    {result, count} =
      QueryCounter.count_source(
        fn -> Content.apply_mutations(batch(n, tag), @ds, scope) end,
        "schema_definitions"
      )

    assert {:ok, {_tx, results}} = result
    assert length(results) == 2 * n
    count
  end

  test "schema reads do not grow with the number of documents", %{scope: scope} do
    small = schema_reads(2, "small", scope)
    large = schema_reads(12, "large", scope)

    assert large == small,
           "a 12-document batch read schema_definitions #{large} times, a 2-document batch #{small}"

    # One stored row and its named type through the scope ladder, plus the
    # redaction fallback. A per-document read would put this in the dozens.
    assert small <= 12, "a 2-document batch read schema_definitions #{small} times"
  end

  test "the memo does not outlive the batch", %{scope: scope} do
    _ = schema_reads(1, "memo", scope)
    refute Process.get(:barkpark_process_memo)

    refute Enum.any?(Process.get(), fn {k, _} -> match?({:barkpark_request_memo, _}, k) end)
  end
end
