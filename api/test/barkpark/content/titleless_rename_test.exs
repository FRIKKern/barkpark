defmodule Barkpark.Content.TitlelessRenameTest do
  @moduledoc """
  task-f20c582a579fa514: a type with no `title` field fills its title column
  from `list_preview.title` (an author's `name`). A rename used to leave the
  column on the OLD name, because the rename's write carries the old title (the
  Studio form and an API patch both merge it from the row) and the derivation
  only filled a blank one.

  Every surface named in the task reads that one column: the old Studio list
  (`PaneBuilder`, `doc.title` before the preview fallback), the desk list rows
  (the same `doc.title`) and the desk search (`Content.search_documents/3`,
  whose `search_vector` is generated from the column). So the column is what
  these tests pin, plus the old Studio list and the search read themselves.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Mutations
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "titleless-rename-#{System.unique_integer([:positive])}"

  @author_schema %{
    "name" => "author",
    "title" => "Forfatter",
    "visibility" => "public",
    "fields" => [
      %{"name" => "name", "title" => "Navn", "type" => "string"},
      %{"name" => "bio", "title" => "Biografi", "type" => "text"}
    ],
    "list_preview" => %{"title" => "name"}
  }

  setup do
    {:ok, _} = Content.upsert_schema(@author_schema, @dataset)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "series",
          "title" => "Serie",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "blurb", "type" => "text"}
          ],
          "list_preview" => %{"title" => "blurb"}
        },
        @dataset
      )

    :ok
  end

  defp author(id, name, extra \\ %{}) do
    {:ok, draft} =
      Content.create_document(
        "author",
        Map.merge(%{"doc_id" => id, "content" => %{"name" => name, "bio" => "Bio."}}, extra),
        @dataset
      )

    draft
  end

  defp column(id) do
    {:ok, doc} = Content.get_document(id, "author", @dataset)
    doc.title
  end

  test "an autosave-shaped write that renames the field moves the column (the old title carried)" do
    draft = author("author-ada", "Ada Lovelace")
    assert draft.title == "Ada Lovelace"

    {:ok, saved} =
      Content.upsert_document(
        "author",
        %{
          "doc_id" => "author-ada",
          "title" => "Ada Lovelace",
          "content" => %{"name" => "Ada Byron", "bio" => "Bio."}
        },
        @dataset
      )

    assert saved.title == "Ada Byron"
    assert column("drafts.author-ada") == "Ada Byron"
  end

  test "the Studio form save (Content.upsert_draft) of a rename moves the column" do
    draft = author("author-form", "Mary Shelley")
    schema = %{fields: @author_schema["fields"], list_preview: %{"title" => "name"}}

    {:ok, saved, _errs} =
      Content.upsert_draft(
        draft,
        "author",
        schema,
        %{"title" => "Mary Shelley", "name" => "Mary W. Shelley", "status" => "draft"},
        @dataset
      )

    assert saved.content["name"] == "Mary W. Shelley"
    assert saved.title == "Mary W. Shelley"
  end

  test "an API patch on a published author with no draft moves the draft's column, and publish carries it" do
    author("author-alan", "Alan Turing")
    {:ok, _} = Content.publish_document("author-alan", "author", @dataset)

    {:ok, _} =
      Mutations.apply_mutations(
        [
          %{
            "patch" => %{
              "id" => "author-alan",
              "type" => "author",
              "set" => %{"name" => "Alan M. Turing"}
            }
          }
        ],
        @dataset
      )

    assert column("drafts.author-alan") == "Alan M. Turing"
    {:ok, published} = Content.publish_document("author-alan", "author", @dataset)
    assert published.title == "Alan M. Turing"
    assert column("author-alan") == "Alan M. Turing"
  end

  test "after a rename, search finds the new name and the old Studio list shows it" do
    author("author-search", "Quentin Oldname")
    {:ok, _} = Content.publish_document("author-search", "author", @dataset)

    {:ok, _} =
      Mutations.apply_mutations(
        [
          %{
            "patch" => %{
              "id" => "author-search",
              "type" => "author",
              "set" => %{"name" => "Quentin Zephyrine"}
            }
          }
        ],
        @dataset
      )

    {:ok, _} = Content.publish_document("author-search", "author", @dataset)

    {hits, _total, _meta} =
      Content.search_documents("Zephyrine", @dataset, type: "author", perspective: :raw)

    assert Enum.any?(hits, &(hit_id(&1) in ["author-search", "drafts.author-search"])),
           "a search for the new name finds nothing: " <> inspect(hits)

    {old_hits, _total, _meta} =
      Content.search_documents("Oldname", @dataset, type: "author", perspective: :raw)

    refute Enum.any?(old_hits, &(hit_id(&1) in ["author-search", "drafts.author-search"])),
           "a search for the old name still finds the renamed author"

    {panes, _editor} = PaneBuilder.build(@dataset, ["author"])
    item = Enum.find(List.last(panes).items, &(&1[:type] == :doc and &1.id == "author-search"))
    assert item, "no author row in the old Studio list"
    assert item.title == "Quentin Zephyrine"
  end

  test "a write that sets its own title together with the rename keeps that title" do
    author("author-own", "Old Own")

    {:ok, saved} =
      Content.upsert_document(
        "author",
        %{"doc_id" => "author-own", "title" => "Chosen", "content" => %{"name" => "New Own"}},
        @dataset
      )

    assert saved.title == "Chosen"
  end

  test "a write that leaves the field as it was leaves a hand-set column as it was" do
    author("author-hand", "Hand Name", %{"title" => "Hand-set title"})
    assert column("drafts.author-hand") == "Hand-set title"

    {:ok, saved} =
      Content.upsert_document(
        "author",
        %{
          "doc_id" => "author-hand",
          "title" => "Hand-set title",
          "content" => %{"name" => "Hand Name", "bio" => "A new bio."}
        },
        @dataset
      )

    assert saved.title == "Hand-set title"
  end

  test "a type WITH a title field: changing its list_preview.title field never touches the column" do
    {:ok, _} =
      Content.create_document(
        "series",
        %{"doc_id" => "series-h", "title" => "Hekne", "content" => %{"blurb" => "One"}},
        @dataset
      )

    {:ok, saved} =
      Content.upsert_document(
        "series",
        %{"doc_id" => "series-h", "title" => "Hekne", "content" => %{"blurb" => "Two"}},
        @dataset
      )

    assert saved.title == "Hekne"
  end

  test "a restore keeps the title it carries" do
    author("author-restore", "Before")

    {:ok, saved} =
      Content.upsert_document(
        "author",
        %{"doc_id" => "author-restore", "title" => "Before", "content" => %{"name" => "After"}},
        @dataset,
        restore: true
      )

    assert saved.title == "Before"
  end

  defp hit_id(hit),
    do:
      Map.get(hit, :doc_id) || Map.get(hit, "doc_id") || Map.get(hit, :id) || Map.get(hit, "_id")
end
