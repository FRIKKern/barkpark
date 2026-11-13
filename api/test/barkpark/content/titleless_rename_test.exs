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

  describe "createOrReplace (task-a2064ff3c8c13417)" do
    # What an SDK client sends back after a fetch: the rendered envelope, which
    # carries the stored title, with the name changed.
    defp replace_with_name(id, name) do
      {:ok, doc} = Content.get_document(id, "author", @dataset)

      envelope =
        doc
        |> Barkpark.Content.Envelope.render()
        |> Map.drop(["_rev"])
        |> Map.put("_id", Barkpark.Content.DraftId.published_id(doc.doc_id))
        |> Map.put("name", name)

      {:ok, _} = Mutations.apply_mutations([%{"createOrReplace" => envelope}], @dataset)
    end

    test "a fetched draft sent back with a new name moves the column" do
      author("author-r", "R1")

      replace_with_name("drafts.author-r", "R2")

      assert column("drafts.author-r") == "R2"
    end

    test "a fetched published author with no draft, sent back with a new name, moves the draft's column" do
      author("author-rp", "P1")
      {:ok, _} = Content.publish_document("author-rp", "author", @dataset)

      replace_with_name("author-rp", "P2")

      assert column("drafts.author-rp") == "P2"
    end

    # #25896 review: the direct publish builds the row through
    # `Writer.build_document/4`, not `create_document`.
    test "a fetched published author sent back with a new name and \"publish\": true moves the published column" do
      author("author-rd", "D1")
      {:ok, _} = Content.publish_document("author-rd", "author", @dataset)
      {:ok, doc} = Content.get_document("author-rd", "author", @dataset)

      envelope =
        doc
        |> Barkpark.Content.Envelope.render()
        |> Map.drop(["_rev"])
        |> Map.put("name", "D2")

      {:ok, _} =
        Mutations.apply_mutations([%{"createOrReplace" => envelope, "publish" => true}], @dataset)

      assert column("author-rd") == "D2"
    end

    # task-ce23f03c4f03c335 (#25942 review): the envelope a client fetched may
    # be the DRAFT twin, which carries the draft's title, not the published one.
    defp direct_publish(from_id, to_id, changes) do
      {:ok, doc} = Content.get_document(from_id, "author", @dataset)

      envelope =
        doc
        |> Barkpark.Content.Envelope.render()
        |> Map.drop(["_rev"])
        |> Map.put("_id", to_id)
        |> Map.merge(changes)

      {:ok, _} =
        Mutations.apply_mutations([%{"createOrReplace" => envelope, "publish" => true}], @dataset)
    end

    defp published_with_renamed_draft(id) do
      author(id, "X1")
      {:ok, _} = Content.publish_document(id, "author", @dataset)

      {:ok, _} =
        Mutations.apply_mutations(
          [%{"patch" => %{"id" => id, "type" => "author", "set" => %{"name" => "X2"}}}],
          @dataset
        )

      assert column("drafts." <> id) == "X2"
    end

    test "a fetched DRAFT sent to the published id with \"publish\": true and a new name moves the column" do
      published_with_renamed_draft("author-dx")

      direct_publish("drafts.author-dx", "author-dx", %{"name" => "X3"})

      assert column("author-dx") == "X3"
    end

    test "with a draft twin, a fetched PUBLISHED envelope and a new name still moves the column" do
      published_with_renamed_draft("author-dp")

      direct_publish("author-dp", "author-dp", %{"name" => "X3"})

      assert column("author-dp") == "X3"
    end

    test "with a draft twin, a title of the client's own stays" do
      published_with_renamed_draft("author-do")

      direct_publish("drafts.author-do", "author-do", %{"name" => "X3", "title" => "Mine"})

      assert column("author-do") == "Mine"
    end
  end

  describe "a name set blank or unset shows what a new author with no name shows" do
    # The rule for the blank case: a new author with a blank name gets no title
    # from the derivation, and every list falls back from there. A rename to
    # blank lands on the same column, so lists and search stop showing a name
    # the document no longer has.
    setup do
      %{fresh: author("author-fresh-blank", "").title}
    end

    test "patch set name to \"\"", %{fresh: fresh} do
      author("author-b1", "Eve")
      patch("author-b1", %{"set" => %{"name" => ""}})
      assert column("drafts.author-b1") == fresh
    end

    test "patch unset name", %{fresh: fresh} do
      author("author-b2", "Eve")
      patch("author-b2", %{"unset" => ["name"]})
      assert column("drafts.author-b2") == fresh
    end

    test "createOrReplace with a blank name", %{fresh: fresh} do
      author("author-b3", "Eve")
      replace_with_name("drafts.author-b3", "   ")
      assert column("drafts.author-b3") == fresh
    end

    test "a write that leaves a blank name blank leaves a hand-set column as it was" do
      author("author-b4", "", %{"title" => "Hand-set"})
      patch("author-b4", %{"set" => %{"bio" => "New bio."}})
      assert column("drafts.author-b4") == "Hand-set"
    end
  end

  defp patch(id, ops) do
    {:ok, _} =
      Mutations.apply_mutations(
        [%{"patch" => Map.merge(%{"id" => id, "type" => "author"}, ops)}],
        @dataset
      )
  end

  defp hit_id(hit),
    do:
      Map.get(hit, :doc_id) || Map.get(hit, "doc_id") || Map.get(hit, :id) || Map.get(hit, "_id")
end
