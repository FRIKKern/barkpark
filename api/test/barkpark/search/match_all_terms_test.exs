defmodule Barkpark.Search.MatchAllTermsTest do
  @moduledoc """
  task-3623955d22974d71 — a multi-word query matches documents that hold every
  word, ranks them first, says which rule ran, and widens to any word only when
  no document holds them all.

  task-7e7891dbf1f488ee — the last word is a prefix of a title or author word,
  a 1-letter last word does not widen the match, and `suggest: true` answers
  from the same match without facets.

  task-c7395e0d27e1121b — field filters run inside the search, so the count and
  the facets describe the filtered match, and named facets count field values.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "match-all-terms-test"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book",
          "visibility" => "public",
          "fields" => [
            %{"name" => "displayName", "type" => "string"},
            %{"name" => "Authors", "type" => "arrayOf", "of" => %{"type" => "string"}},
            %{"name" => "Format", "type" => "string"},
            %{"name" => "Language", "type" => "arrayOf", "of" => %{"type" => "string"}},
            %{"name" => "Description", "type" => "string"}
          ]
        },
        @ds,
        scope
      )

    book = fn id, content ->
      {:ok, _} =
        Content.create_document("book", %{"doc_id" => id, "content" => content}, @ds, scope)

      {:ok, _} = Content.publish_document(id, "book", @ds, scope)
      id
    end

    both =
      book.("both", %{
        "displayName" => "Grammatikk for alle",
        "Description" => "Norsk grammatikk forklart.",
        "Format" => "Lydbok",
        "Language" => ["Bokmål"]
      })

    for n <- 1..6 do
      book.("norsk-#{n}", %{
        "displayName" => "Bok #{n}",
        "Description" => "Norsk roman",
        "Format" => if(rem(n, 2) == 0, do: "Lydbok", else: "Heftet"),
        "Language" => if(n == 1, do: ["Nynorsk"], else: ["Bokmål"])
      })
    end

    for n <- 1..3 do
      book.("gram-#{n}", %{"displayName" => "Tekst #{n}", "Description" => "Om grammatikk"})
    end

    hamsun =
      book.("hamsun", %{
        "displayName" => "Markens grøde",
        "Authors" => ["Knut Hamsun"],
        "Description" => "Roman"
      })

    book.("hammer", %{"displayName" => "Knut og hammeren", "Description" => "Barnebok"})

    %{scope: scope, both: both, hamsun: hamsun}
  end

  defp search(q, scope, opts \\ []) do
    {hits, total, meta} = Content.search_documents(q, @ds, [type: "book"] ++ opts ++ scope)
    {Enum.map(hits, & &1.doc_id), total, meta}
  end

  test "two words match only the document that holds both, and the response says all",
       %{scope: scope, both: both} do
    assert {[^both], 1, %{match: "all", recovery: nil}} = search("norsk grammatikk", scope)
  end

  test "with match: :any the document holding both words ranks first", %{scope: scope, both: both} do
    {[first | _] = ids, total, meta} = search("norsk grammatikk", scope, match: :any)
    assert first == both
    assert total == 10
    assert length(ids) == 10
    assert meta.match == "any"
  end

  test "when no document holds every word, any word will do, ranked by how many it holds",
       %{scope: scope, both: both} do
    {[first | _], total, meta} = search("grammatikk zzyzx", scope)
    assert meta.recovery == "match_any"
    assert meta.match == "any"
    assert total == 4
    assert first == both or first in ["gram-1", "gram-2", "gram-3"]
  end

  test "the last word is a prefix of an author or title word, and that document ranks first",
       %{scope: scope, hamsun: hamsun} do
    {[first | _], _total, _} = search("knut ham", scope)
    assert first == hamsun
  end

  test "a 1-letter last word does not widen the match", %{scope: scope} do
    {_, base_total, _} = search("norsk", scope)
    {_, total, _} = search("norsk g", scope)
    assert total == base_total
  end

  test "suggest: true answers the same first hit and count, without facets",
       %{scope: scope, hamsun: hamsun} do
    {[first | _], total, meta} = search("knut ham", scope, suggest: true)
    {_, full_total, _} = search("knut ham", scope)
    assert first == hamsun
    assert total == full_total
    assert meta.facets == %{}
  end

  test "field filters run inside the search: count and facets describe the filtered match",
       %{scope: scope} do
    {_, all_total, _} = search("norsk", scope)
    assert all_total == 7

    {ids, total, meta} =
      search("norsk", scope,
        filter_map: %{"Format" => "Lydbok"},
        facet_fields: ["Language", "Format"]
      )

    assert total == 4
    assert length(ids) == 4
    assert [%{"count" => 4, "label" => "book"}] = meta.facets["type"]
    assert %{"Format" => [%{"label" => "Lydbok", "count" => 4}]} = meta.facets["fields"]
    assert [%{"label" => "Bokmål", "count" => 4}] = meta.facets["fields"]["Language"]
  end

  test "offset pages through the whole match set past the ranking pool", %{scope: scope} do
    pages =
      for offset <- [0, 3, 6] do
        {ids, total, _} = search("norsk", scope, limit: 3, offset: offset, ranking_pool_size: 2)
        assert total == 7
        ids
      end

    assert pages |> List.flatten() |> Enum.uniq() |> length() == 7
  end
end
