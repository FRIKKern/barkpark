defmodule BarkparkWeb.Studio.PaneBuilderReferenceCountTest do
  @moduledoc """
  Gyldendal parity E9 — the agency desk's two count-based lists, rendered.

  Sanity writes them as a correlated count:

      _type == "category" && count(*[_type == "publication" && references(^._id)]) > 0
      _type == "category" && count(*[_type == "publication" && references(^._id)]) == 0

  A declared `documentTypeList` carrying `referencedBy` / `notReferencedBy`
  renders the same two sets, and the pane reports no filter error — the shape a
  desk node gets when its filter cannot be applied.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "refcount-panes-#{System.unique_integer([:positive])}"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "category",
          "title" => "Kategori",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Tittel", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "publication",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{
              "name" => "category",
              "title" => "Kategori",
              "type" => "reference",
              "to" => ["category"]
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "deskStructure",
          "title" => "Desk",
          "singleton" => true,
          "visibility" => "private",
          "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
        },
        @dataset
      )

    for {id, title} <- [{"cat-krim", "Krim"}, {"cat-poesi", "Poesi"}] do
      {:ok, _} =
        Content.create_document(
          "category",
          %{"doc_id" => id, "title" => title, "content" => %{}},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "category", @dataset)
    end

    {:ok, _} =
      Content.create_document(
        "publication",
        %{
          "doc_id" => "pub-1",
          "title" => "Nordic Noir",
          "content" => %{"category" => "cat-krim"}
        },
        @dataset
      )

    {:ok, _} = Content.publish_document("pub-1", "publication", @dataset)

    items = [
      %{
        "kind" => "documentTypeList",
        "id" => "kategorier-med-utgivelser",
        "type" => "category",
        "title" => "Kategorier med utgivelser",
        "filter" => %{"_id" => %{"referencedBy" => "publication"}}
      },
      %{
        "kind" => "groupBy",
        "id" => "etter-kategori",
        "type" => "publication",
        "by" => "content.category",
        "over" => "category",
        "title" => "Etter kategori",
        "overFilter" => %{"_id" => %{"referencedBy" => "publication"}}
      },
      %{
        "kind" => "documentTypeList",
        "id" => "kategorier-uten-utgivelser",
        "type" => "category",
        "title" => "Kategorier uten utgivelser",
        "filter" => %{"_id" => %{"notReferencedBy" => "publication"}}
      },
      %{
        "kind" => "documentTypeList",
        "id" => "utgivelser",
        "type" => "publication",
        "title" => "Utgivelser"
      },
      # task-d99d878b061b435a: items whose filter names no type or field.
      %{
        "kind" => "documentTypeList",
        "id" => "skrivefeil",
        "type" => "category",
        "title" => "Skrivefeil",
        "filter" => %{"_id" => %{"referencedBy" => "publikasjon"}}
      },
      %{
        "kind" => "groupBy",
        "id" => "feil-gruppe",
        "type" => "publication",
        "by" => "content.category",
        "over" => "category",
        "title" => "Feil gruppe",
        "overFilter" => %{"_id" => %{"referencedBy" => "publication.nope"}}
      }
    ]

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        @dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", @dataset)
    :ok
  end

  defp titles(node_id) do
    {panes, _editor} = PaneBuilder.build(@dataset, [node_id])
    pane = List.last(panes)

    refute pane[:filter_error],
           "the desk node reported a filter error: #{inspect(pane[:filter_error])}"

    assert pane.type_name == "category"
    pane.items |> Enum.map(& &1.title) |> Enum.sort()
  end

  test "the referenced list holds only the category a publication points at" do
    assert titles("kategorier-med-utgivelser") == ["Krim"]
  end

  test "the unreferenced list is its complement" do
    assert titles("kategorier-uten-utgivelser") == ["Poesi"]
  end

  test "a groupBy groups over the referenced rows only, like Sanity's «Etter kategori»" do
    {panes, _editor} = PaneBuilder.build(@dataset, ["etter-kategori"])
    pane = List.last(panes)

    # One child list per category a publication points at — and none for the
    # unused one, which would otherwise be an empty group in the desk.
    assert Enum.map(pane.items, & &1.title) == ["Krim"]
  end

  test "an item whose filter names no type opens as an empty list stating why" do
    {panes, _editor} = PaneBuilder.build(@dataset, ["skrivefeil"])
    pane = List.last(panes)

    assert pane.items == []
    assert pane.filter_error =~ "names no document type in this dataset: \"publikasjon\""
  end

  test "a groupBy that cannot be built opens as an empty list stating why, the rest stays" do
    {panes, _editor} = PaneBuilder.build(@dataset, ["feil-gruppe"])
    pane = List.last(panes)

    assert pane.title == "Feil gruppe"
    assert pane.items == []
    assert pane.filter_error =~ "names no field \"nope\""

    assert titles("kategorier-med-utgivelser") == ["Krim"]
  end

  # task-cca3c6d48e57097e: the Studio builds the desk for every URL. On gyl the
  # «Etter virksomhet» group's reference test over 18,020 products ran inside
  # every document open. The Studio now builds a group's children only when a
  # walk enters the group.
  describe "deferred groupBy children" do
    test "opening a document elsewhere on the desk runs no reference test" do
      sqls = capture_document_sql(fn -> PaneBuilder.build(@dataset, ["utgivelser", "pub-1"]) end)

      refute Enum.any?(sqls, &(&1 =~ "jsonb_path_query_array")),
             "a document open ran a reference-count query: #{inspect(sqls)}"
    end

    test "a group's child list still opens from its own path" do
      {panes, _editor} = PaneBuilder.build(@dataset, ["etter-kategori", "desk-1-cat-krim"])

      assert Enum.map(Enum.at(panes, -2).items, & &1.title) == ["Krim"]
      assert List.last(panes).items |> Enum.map(& &1.title) == ["Nordic Noir"]
    end

    test "the structure API still carries the children; the Studio build defers them" do
      eager = Barkpark.Structure.build(@dataset)
      deferred = Barkpark.Structure.build(@dataset, defer_group_by: true)

      group = fn tree -> Enum.find(tree.items, &(&1.id == "etter-kategori")) end

      assert Enum.map(group.(eager).items, & &1.title) == ["Krim"]
      assert group.(deferred).items == []
      assert {:group_by, _item, _idx} = group.(deferred).deferred

      expanded = Barkpark.Structure.expand(group.(deferred), @dataset, [])
      assert Enum.map(expanded.items, & &1.title) == ["Krim"]
    end
  end

  defp capture_document_sql(fun) do
    parent = self()
    id = "deferred-group-by-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _e, _m, meta, _ ->
        if self() == parent and meta[:source] == "documents", do: send(parent, {id, meta[:query]})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    collect(id, [])
  end

  defp collect(id, acc) do
    receive do
      {^id, sql} -> collect(id, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
