defmodule Barkpark.Search.LastWordPrefixTest do
  @moduledoc """
  Search follows typing (task-2590983e26a88496): the last word of a query, and
  any `word*`, prefix-matches content text, as Sanity's global search does.
  `excer` finds a post whose excerpt says "Short excerpt"; before, content text
  matched whole stemmed words only and a prefix reached titles and slugs alone.
  An earlier word in the query still matches whole words.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "production"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "post", "visibility" => "public"},
        @ds,
        scope
      )

    for {id, title, excerpt} <- [
          {"p1", "Alpha", "Short excerpt about gardens"},
          {"p2", "Beta", "A newsletter about tools"},
          {"p3", "Gamma", "Nothing to see"}
        ] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => title, "content" => %{"excerpt" => excerpt}},
          @ds,
          scope
        )
    end

    %{scope: scope}
  end

  defp ids(q, scope) do
    {hits, _total, _} = Content.search_documents(q, @ds, [perspective: :raw] ++ scope)
    hits |> Enum.map(& &1.doc_id) |> Enum.sort()
  end

  test "the last word prefix-matches content text", %{scope: scope} do
    assert ids("excer", scope) == ["drafts.p1"]
    assert ids("news", scope) == ["drafts.p2"]
    assert ids("gard*", scope) == ["drafts.p1"]
  end

  test "whole words still match, and only the last word is a prefix", %{scope: scope} do
    assert ids("excerpt", scope) == ["drafts.p1"]
    # "excer" is not the last word here, so it matches whole words only: the
    # excerpt post stays out, the post that says "tools" comes back.
    assert ids("excer tools", scope) == ["drafts.p2"]
  end
end
