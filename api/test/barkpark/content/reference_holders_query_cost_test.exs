defmodule Barkpark.Content.ReferenceHoldersQueryCostTest do
  @moduledoc """
  run-perf latency scan (27 Oct): backlinks were the studio's slowest hot read,
  because `Content.Query.list_reference_holders/3` ran one documents query per
  schema in the dataset, also for a type with no field that can hold a link
  (its predicate was `false OR false …`). A type with no reference, image,
  file or reference/asset-array field is now skipped without a query.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content

  @ds "ref-cost"

  defp schema!(name, fields) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
        @ds
      )
  end

  setup do
    schema!("rcperson", [%{"name" => "name", "type" => "string"}])

    schema!("rcarticle", [
      %{"name" => "title", "type" => "string"},
      %{"name" => "author", "type" => "reference", "refType" => "rcperson"}
    ])

    schema!("rcgallery", [%{"name" => "shots", "type" => "arrayOf", "of" => %{"type" => "image"}}])

    schema!("rcnote", [%{"name" => "body", "type" => "text"}])
    schema!("rctagged", [%{"name" => "tags", "type" => "arrayOf", "of" => %{"type" => "string"}}])

    {:ok, _} = Content.create_document("rcperson", %{"doc_id" => "ada", "title" => "Ada"}, @ds)

    {:ok, _} =
      Content.create_document(
        "rcarticle",
        %{"doc_id" => "a1", "title" => "A1", "content" => %{"author" => %{"_ref" => "ada"}}},
        @ds
      )

    # Text that names the id is not a link.
    {:ok, _} =
      Content.create_document("rcnote", %{"doc_id" => "n1", "content" => %{"body" => "ada"}}, @ds)

    :ok
  end

  defp count_document_queries(fun) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    me = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _, _, %{source: source}, _ ->
        if self() == me and source == "documents", do: Agent.update(counter, &(&1 + 1))
      end,
      nil
    )

    try do
      {fun.(), Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler)
      Agent.stop(counter)
    end
  end

  test "only the types that can hold a link are queried, and the holder is found" do
    schemas = Content.list_schemas(@ds, [])

    {holders, queries} =
      count_document_queries(fn ->
        Content.Query.list_reference_holders("ada", @ds, schemas: schemas)
      end)

    assert Enum.map(holders, &{&1.doc_id, &1.via_field}) == [{"drafts.a1", "author"}]
    # rcarticle (reference) and rcgallery (image array); not rcperson, rcnote, rctagged.
    assert queries == 2
  end
end
