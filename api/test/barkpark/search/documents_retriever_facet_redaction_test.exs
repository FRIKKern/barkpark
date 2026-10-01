defmodule Barkpark.Search.DocumentsRetrieverFacetRedactionTest do
  @moduledoc """
  task-3c68de39a19285c4, the facet half: a search facet label never echoes a
  field value the caller cannot read.

  `meta.facets.author` / `.category` are built from `content->>'author'` /
  `content->>'category'`. Results run through `Envelope.render/3` and drop a
  private field, but facets did not. A public type that declares `author`
  private still told an anonymous caller every author's name, and how many
  documents each one had.

  The search_vector half of the row (a private field's words still match) is
  NOT addressed here; see the row's note.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext

  @ds "facet-redaction-test"

  defp corpus! do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "memo",
          "title" => "Memo",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "string", "private" => true},
            %{"name" => "category", "type" => "string"}
          ]
        },
        @ds,
        scope
      )

    # A second public type that declares nothing: its author is public.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "note", "title" => "Note", "visibility" => "public", "fields" => []},
        @ds,
        scope
      )

    for {type, id, author} <- [
          {"memo", "m1", "Secret Sam"},
          {"memo", "m2", "Secret Sam"},
          {"note", "n1", "Open Olga"}
        ] do
      {:ok, _} =
        Content.create_document(
          type,
          %{
            "doc_id" => id,
            "title" => "Zephyrine #{id}",
            "author" => author,
            "category" => "news"
          },
          @ds,
          scope
        )

      {:ok, _} = Content.publish_document(id, type, @ds, scope)
    end

    scope
  end

  defp labels(meta, dim),
    do: meta.facets |> Map.get(dim, []) |> Map.new(&{&1["label"], &1["count"]})

  test "anonymous: a private author never appears as a facet label; a public one does" do
    scope = corpus!()
    # What the HTTP door hands the retriever for a tokenless caller.
    anon = CallerContext.anonymous()

    {_hits, count, meta} =
      Content.search_documents("zephyrine", @ds, [caller_context: anon] ++ scope)

    assert count == 3
    authors = labels(meta, "author")
    refute Map.has_key?(authors, "Secret Sam"), "a private field's value leaked as a facet label"
    assert authors["Open Olga"] == 1
    # The public category facet still counts every document.
    assert labels(meta, "category")["news"] == 3
  end

  test "no caller context reads as anonymous: private author hidden, public facets intact" do
    scope = corpus!()
    {_hits, _count, meta} = Content.search_documents("zephyrine", @ds, scope)
    refute Map.has_key?(labels(meta, "author"), "Secret Sam")
    assert labels(meta, "author")["Open Olga"] == 1
    assert labels(meta, "category")["news"] == 3
  end

  test "an admin caller still sees every author bucket, with the same totals as before" do
    scope = corpus!()
    admin = %CallerContext{principal_type: :api_token, is_admin: true}

    {_hits, _count, meta} =
      Content.search_documents("zephyrine", @ds, [caller_context: admin] ++ scope)

    authors = labels(meta, "author")
    assert authors["Secret Sam"] == 2
    assert authors["Open Olga"] == 1
  end

  test "a read token that may not read the private field is redacted like anonymous" do
    scope = corpus!()
    reader = %CallerContext{principal_type: :api_token, token_id: "t-r", roles: ["read"]}

    {_hits, _count, meta} =
      Content.search_documents("zephyrine", @ds, [caller_context: reader] ++ scope)

    refute Map.has_key?(labels(meta, "author"), "Secret Sam")
    assert labels(meta, "author")["Open Olga"] == 1
  end
end
