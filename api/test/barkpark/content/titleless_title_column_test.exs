defmodule Barkpark.Content.TitlelessTitleColumnTest do
  @moduledoc """
  Gyldendal parity E1.8 (task-b732cbaf366456e9, criteria 2–4), spelled ONLY in
  terms of the public Content API so it runs unchanged on origin/main (where it
  is red): a type with no `title` field fills the document title column from
  `list_preview.title`, and its desk rows show that value.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "titleless-col-#{System.unique_integer([:positive])}"

  @author_fields [
    %{"name" => "name", "title" => "Navn", "type" => "string"},
    %{"name" => "slug", "title" => "Slug (URL)", "type" => "slug"},
    %{"name" => "bio", "title" => "Biografi", "type" => "text"}
  ]

  @author_schema %{
    "name" => "author",
    "title" => "Forfatter",
    "visibility" => "public",
    "fields" => @author_fields,
    "list_preview" => %{"title" => "name", "subtitle" => "slug"}
  }

  describe "the write chokepoint" do
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

    test "create + publish of a titleless author lands its name in the title column" do
      {:ok, draft} =
        Content.create_document(
          "author",
          %{
            "doc_id" => "author-graff",
            "content" => %{"name" => "Sverre Graff", "slug" => "sverre-graff"}
          },
          @dataset
        )

      assert draft.title == "Sverre Graff"

      {:ok, published} = Content.publish_document("author-graff", "author", @dataset)
      assert published.title == "Sverre Graff"
      {:ok, read} = Content.get_document("author-graff", "author", @dataset)

      assert read.title == "Sverre Graff",
             "the read path (what /v1/data/doc and the pill see) still says: " <>
               inspect(read.title)
    end

    test "an existing titleless row is back-filled on its next upsert, and a rename follows the field" do
      {:ok, _} =
        Content.create_document(
          "author",
          %{"doc_id" => "author-old", "title" => "legacy", "content" => %{"name" => "Old Name"}},
          @dataset
        )

      # Simulate a row written before this rule: blank the column directly.
      {:ok, row} = Content.get_document("drafts.author-old", "author", @dataset)
      {:ok, _} = row |> Ecto.Changeset.change(title: nil) |> Barkpark.Repo.update()

      {:ok, saved} =
        Content.upsert_document(
          "author",
          %{"doc_id" => "author-old", "content" => %{"name" => "New Name"}},
          @dataset
        )

      assert saved.title == "New Name"
    end

    test "a type WITH a title field is byte-identical: list_preview.title never overrides a declared title" do
      {:ok, draft} =
        Content.create_document(
          "series",
          %{
            "doc_id" => "series-x",
            "title" => "Hekne",
            "content" => %{"blurb" => "Not the title"}
          },
          @dataset
        )

      assert draft.title == "Hekne"

      {:ok, blank} =
        Content.create_document(
          "series",
          %{"doc_id" => "series-y", "content" => %{"blurb" => "Not the title"}},
          @dataset
        )

      assert blank.title in [nil, ""],
             "a titled type with a blank title must stay blank, got: " <> inspect(blank.title)
    end
  end

  describe "desk rows" do
    setup do
      {:ok, _} = Content.upsert_schema(@author_schema, @dataset)
      :ok
    end

    test "a titleless author row shows its name even when the stored column is blank" do
      {:ok, _} =
        Content.create_document(
          "author",
          %{"doc_id" => "author-row", "content" => %{"name" => "Terje Ommundsen"}},
          @dataset
        )

      {:ok, _} = Content.publish_document("author-row", "author", @dataset)
      {:ok, row} = Content.get_document("author-row", "author", @dataset)
      {:ok, _} = row |> Ecto.Changeset.change(title: nil) |> Barkpark.Repo.update()

      {panes, _editor} = PaneBuilder.build(@dataset, ["author"])
      pane = List.last(panes)
      item = Enum.find(pane.items, &(&1[:type] == :doc and &1.id == "author-row"))
      assert item, "no author row in: " <> inspect(pane.items)
      assert item.title == "Terje Ommundsen"
    end

    test "a titleless document with no list_preview value still renders an id-bearing title, never blank" do
      {:ok, _} =
        Content.create_document(
          "author",
          %{"doc_id" => "author-blank", "content" => %{"slug" => "x"}},
          @dataset
        )

      {:ok, _} = Content.publish_document("author-blank", "author", @dataset)

      {panes, _} = PaneBuilder.build(@dataset, ["author"])
      item = Enum.find(List.last(panes).items, &(&1[:type] == :doc and &1.id == "author-blank"))

      assert is_binary(item.title) and item.title =~ ~r/^Untitled .*·/,
             "expected the unnamed-row spelling with the id tail, got: " <> inspect(item.title)
    end
  end
end
