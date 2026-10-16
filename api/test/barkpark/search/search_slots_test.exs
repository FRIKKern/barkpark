defmodule Barkpark.Search.SearchSlotsTest do
  @moduledoc """
  task-3c6d02392d430c98 — a type with no `title` field fills the weighted title
  and author slots of the search index from its schema, so the fold, typo and
  prefix arms work on it, including for rows written with triggers disabled
  (a bundle import).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Search.SearchSlots

  @ds "search-slots-test"

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
            %{"name" => "Author", "type" => "string"},
            %{"name" => "Authors", "type" => "arrayOf", "of" => %{"type" => "string"}},
            %{"name" => "Description", "type" => "string"}
          ]
        },
        @ds,
        scope
      )

    %{scope: scope, ws: ws}
  end

  defp book!(scope, id, content) do
    {:ok, _} =
      Content.create_document("book", %{"doc_id" => id, "content" => content}, @ds, scope)

    {:ok, _} = Content.publish_document(id, "book", @ds, scope)
    id
  end

  defp slots(id) do
    %{rows: [[title, author]]} =
      Repo.query!(
        "SELECT search_title, search_author FROM documents " <>
          "WHERE doc_id IN ($1::text, 'drafts.' || $1::text) ORDER BY doc_id LIMIT 1",
        [id]
      )

    {title, author}
  end

  defp ids(q, scope, opts \\ []) do
    {hits, total, meta} = Content.search_documents(q, @ds, [type: "book"] ++ opts ++ scope)
    {Enum.map(hits, & &1.doc_id), total, meta}
  end

  test "a type with no title field takes displayName and Author/Authors into the slots",
       %{scope: scope} do
    book!(scope, "b1", %{
      "displayName" => "Min kamp 1",
      "Author" => "Karl Ove Knausgård",
      "Authors" => ["Karl Ove Knausgård", "Geir Gulliksen"]
    })

    # Author and Authors repeat one name: it is kept once.
    assert slots("b1") == {"Min kamp 1", "Karl Ove Knausgård Geir Gulliksen"}
  end

  test "the fold reaches the author slot and the body: knausgard and knausgaard find Knausgård",
       %{scope: scope} do
    by = book!(scope, "by", %{"displayName" => "Om våren", "Authors" => ["Karl Ove Knausgård"]})

    about =
      book!(scope, "about", %{
        "displayName" => "Lesninger",
        "Description" => "Om Knausgård og hans samtid."
      })

    book!(scope, "other", %{"displayName" => "Ingenting her"})

    for q <- ["knausgard", "knausgaard", "Knausgård", "knausg"] do
      {found, _total, _} = ids(q, scope)
      assert by in found, "#{q} missed the book by the author: #{inspect(found)}"
      assert about in found or q == "knausg", "#{q} missed the description: #{inspect(found)}"
      refute "other" in found
    end

    # The author's book ranks above the one that only mentions the name.
    {[first | _], _, _} = ids("knausgard", scope)
    assert first == by
  end

  test "a typo in the search title is found through the title slot", %{scope: scope} do
    hit = book!(scope, "hp", %{"displayName" => "Harry Potter og de vises stein"})
    book!(scope, "hx", %{"displayName" => "Harry og havet"})

    {found, _total, _} = ids("harry poter", scope)
    assert hd(found) == hit
  end

  test "a field marked search: title wins over the title column and the defaults",
       %{scope: scope} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "card",
          "title" => "Card",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "headline", "type" => "string", "search" => "title"},
            %{"name" => "writer", "type" => "string", "search" => "author"}
          ]
        },
        @ds,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "card",
        %{
          "doc_id" => "c1",
          "title" => "Internal code 7",
          "content" => %{"headline" => "Vinterhagen", "writer" => "Åse Ødegård"}
        },
        @ds,
        scope
      )

    assert slots("c1") == {"Vinterhagen", "Åse Ødegård"}
  end

  test "list_preview.title names the search title of a type without a title field",
       %{scope: scope} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "person",
          "title" => "Person",
          "visibility" => "public",
          "list_preview" => %{"title" => "fullName"},
          "fields" => [
            %{"name" => "fullName", "type" => "string"},
            %{"name" => "name", "type" => "string"}
          ]
        },
        @ds,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "person",
        %{"doc_id" => "p1", "content" => %{"fullName" => "Sigrid Undset", "name" => "undset"}},
        @ds,
        scope
      )

    # A Studio or API write derives the `title` column from the preview field
    # (TitleDerivation), and the search title is that column.
    assert {nil, _} = slots("p1")

    # A bundle import writes the row as stored elsewhere, with no title column:
    # the slot then carries the preview field.
    Repo.query!(
      "UPDATE documents SET title = NULL WHERE doc_id IN ('p1', 'drafts.p1')",
      []
    )

    assert {"Sigrid Undset", _} = slots("p1")
  end

  test "a schema change recomputes the slots of the type's documents", %{scope: scope} do
    book!(scope, "s1", %{"displayName" => "Sult", "Description" => "Roman"})
    assert {"Sult", _} = slots("s1")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book",
          "visibility" => "public",
          "fields" => [
            %{"name" => "displayName", "type" => "string"},
            %{"name" => "Description", "type" => "string", "search" => "title"}
          ]
        },
        @ds,
        scope
      )

    assert {"Roman", _} = slots("s1")
  end

  test "a row with no slot stores the title folds the search would compute from its title",
       %{scope: scope, ws: ws} do
    # task-146f3a4fd5c2f348: stored, a search reads them; NULL, it folded every row's title.
    {:ok, _} =
      Content.create_document("note", %{"doc_id" => "n1", "title" => "Ærlig Åse"}, @ds, scope)

    same = """
    SELECT search_title IS NULL AND search_author IS NULL,
           search_names_fold IS NOT NULL
             AND search_title_fold = bp_fold(coalesce(nullif(title, ''), ''))
             AND search_names_fold = bp_fold(coalesce(nullif(title, ''), ''))
             AND search_names_tsv =
                   setweight(to_tsvector('simple', bp_fold(coalesce(nullif(title, ''), ''))), 'A')
    FROM documents WHERE doc_id = 'drafts.n1'
    """

    assert %{rows: [[true, true]]} = Repo.query!(same)

    # A bundle import's COPY leaves them NULL; refresh/1 stores them.
    Repo.query!(
      "UPDATE documents SET search_title_fold = NULL, search_names_fold = NULL, " <>
        "search_names_tsv = NULL WHERE doc_id = 'drafts.n1'"
    )

    assert SearchSlots.refresh(workspace_id: ws.id) >= 1
    assert %{rows: [[true, true]]} = Repo.query!(same)
  end

  test "refresh/1 fills the slots of rows written with user triggers disabled", %{
    scope: scope,
    ws: ws
  } do
    id =
      book!(scope, "imported", %{"displayName" => "Markens grøde", "Authors" => ["Knut Hamsun"]})

    # What a bundle import's COPY (user triggers disabled) leaves behind: the
    # slots of another box, or none. Writing only the slot columns does not
    # fire the slot trigger, so this is the same state.
    Repo.query!(
      "UPDATE documents SET search_title = NULL, search_author = NULL WHERE doc_id = $1",
      [id]
    )

    assert slots(id) == {nil, nil}

    assert SearchSlots.refresh(workspace_id: ws.id) >= 1
    assert slots(id) == {"Markens grøde", "Knut Hamsun"}
    assert SearchSlots.refresh(workspace_id: ws.id) == 0

    {found, _, _} = ids("knut ham", scope)
    assert hd(found) == id
  end
end
