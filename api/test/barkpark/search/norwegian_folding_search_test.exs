defmodule Barkpark.Search.NorwegianFoldingSearchTest do
  @moduledoc """
  task-1429eb7cfc6217ea — document search folds æ/ø/å on both sides, so the
  plain-ASCII and transliterated spellings find the Norwegian title, and the
  exact spelling still finds it first.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  @ds "fold-search-test"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public"},
        @ds,
        scope
      )

    ids =
      for title <- [
            "Ærlig tale om budsjettet for neste periode",
            "Økonomi for alle kommunene i hele fylket",
            "Årsrapport 2025 med vedlegg og revisjonsberetning",
            "Unrelated note"
          ],
          into: %{} do
        id = "fold-#{System.unique_integer([:positive])}"

        {:ok, _} =
          Content.create_document("post", %{"doc_id" => id, "title" => title}, @ds, scope)

        {:ok, _} = Content.publish_document(id, "post", @ds, scope)
        {title, id}
      end

    %{scope: scope, ids: ids}
  end

  defp hits(q, scope) do
    {hits, _total, _meta} = Content.search_documents(q, @ds, scope)
    Enum.map(hits, & &1.doc_id)
  end

  test "ASCII and transliterated spellings find the Norwegian title", %{scope: scope, ids: ids} do
    for {query, title} <- [
          {"aerlig", "Ærlig tale om budsjettet for neste periode"},
          {"okonomi", "Økonomi for alle kommunene i hele fylket"},
          {"oekonomi", "Økonomi for alle kommunene i hele fylket"},
          {"arsrapport", "Årsrapport 2025 med vedlegg og revisjonsberetning"},
          {"aarsrapport", "Årsrapport 2025 med vedlegg og revisjonsberetning"}
        ] do
      found = hits(query, scope)

      assert ids[title] in found,
             "#{inspect(query)} did not find #{inspect(title)}: #{inspect(found)}"

      refute ids["Unrelated note"] in found
    end
  end

  test "the exact Norwegian spelling still matches, and ranks first", %{scope: scope, ids: ids} do
    for {query, title} <- [
          {"Ærlig", "Ærlig tale om budsjettet for neste periode"},
          {"økonomi", "Økonomi for alle kommunene i hele fylket"},
          {"årsrapport", "Årsrapport 2025 med vedlegg og revisjonsberetning"}
        ] do
      assert [first | _] = hits(query, scope)
      assert first == ids[title], "#{inspect(query)}: #{inspect(title)} is not first"
    end
  end

  test "an excluded folded term excludes the Norwegian title", %{scope: scope, ids: ids} do
    # "alle" alone finds it; excluding the folded spelling must remove it.
    assert ids["Økonomi for alle kommunene i hele fylket"] in hits("alle", scope)
    refute ids["Økonomi for alle kommunene i hele fylket"] in hits("alle -okonomi", scope)
  end
end
