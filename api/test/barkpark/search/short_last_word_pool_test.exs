defmodule Barkpark.Search.ShortLastWordPoolTest do
  @moduledoc """
  task-7db7f8fe8b17a58e — a 1-letter last word stays out of the match (it has
  no trigram to probe) but picks the ranking pool: "bulk item 1" over many bulk
  items ranks Bulk item 1x first, as Sanity's prefix does, even when the pool
  of the newest matches holds none of them.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Search.DocumentsRetriever

  @ds "short-last-word-pool-test"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "item",
          "title" => "Item",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @ds,
        scope
      )

    # Bulk item 10-19 first, so the newest matches (the pool without the hint)
    # are all Bulk item 2x and 3x.
    for n <- 10..39 do
      id = "bulk-#{n}"

      {:ok, _} =
        Content.create_document(
          "item",
          %{"doc_id" => id, "title" => "Bulk item #{n}"},
          @ds,
          scope
        )

      {:ok, _} = Content.publish_document(id, "item", @ds, scope)

      from(d in Barkpark.Content.Document, where: d.doc_id == ^id)
      |> Repo.update_all(set: [updated_at: DateTime.add(~U[2026-10-01 00:00:00Z], n, :second)])
    end

    %{scope: scope}
  end

  # The retriever itself, so the small pool binds (the pipeline keeps its own).
  defp search(q, scope, opts) do
    parsed = %{terms: String.split(q), phrases: [], prefixes: [], excludes: []}

    {hits, total, _} =
      DocumentsRetriever.search(
        @ds,
        parsed,
        %{},
        [type: "item", ranking_pool_size: 5] ++ opts ++ scope
      )

    {Enum.map(hits, & &1.title), total}
  end

  for match <- [:all, :any] do
    test "match #{match}: \"bulk item 1\" ranks Bulk item 1x first past a pool of the newest",
         %{scope: scope} do
      {titles, total} = search("bulk item 1", scope, match: unquote(match), limit: 5)
      assert length(titles) == 5
      assert Enum.all?(titles, &String.starts_with?(&1, "Bulk item 1")), inspect(titles)
      # Still not a filter: the count is the words' match.
      assert total == 30

      {titles, _} = search("bulk item 3", scope, match: unquote(match), limit: 5)
      assert Enum.all?(titles, &String.starts_with?(&1, "Bulk item 3")), inspect(titles)
    end
  end

  test "without a 1-letter last word the pool is as before", %{scope: scope} do
    {titles, total} = search("bulk item", scope, match: :all, limit: 5)
    assert total == 30
    assert length(titles) == 5
  end
end
