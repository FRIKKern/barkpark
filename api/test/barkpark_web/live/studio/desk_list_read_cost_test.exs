defmodule BarkparkWeb.Studio.DeskListReadCostTest do
  @moduledoc """
  What one desk list read costs. The page holds the desk tree, so a list it
  names by its node is read without building the tree again: the rows are
  the ones `PaneBuilder.build/3` gives for the same path, and the read runs
  only the list's own queries.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Structure
  alias BarkparkWeb.Studio.Desk.PaneComponent
  alias BarkparkWeb.Studio.Desk.Rows
  alias BarkparkWeb.Studio.Desk.Tree
  alias BarkparkWeb.Studio.StructureCopy

  @article "dlrc_article"
  @author "dlrc_author"

  setup do
    n = System.unique_integer([:positive])
    dataset = "desk-read-cost-#{n}"

    upsert = fn name, extra ->
      {:ok, _} =
        Content.upsert_schema(
          Map.merge(
            %{
              "name" => name,
              "title" => name,
              "visibility" => "public",
              "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
            },
            extra
          ),
          dataset
        )
    end

    upsert.(@author, %{"title" => "Authors"})

    upsert.(@article, %{
      "title" => "Articles",
      "list_preview" => %{"subtitle" => "author.title"},
      "desk" => %{
        "orderings" => [%{"field" => "title", "direction" => "asc"}],
        "sortOrderings" => [
          %{
            "name" => "titleDesc",
            "title" => "Title, Z first",
            "by" => [%{"field" => "title", "direction" => "desc"}]
          }
        ]
      },
      "fields" => [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "category", "title" => "Category", "type" => "string"},
        %{
          "name" => "parent",
          "title" => "Parent",
          "type" => "reference",
          "to" => [%{"type" => @article}]
        },
        %{
          "name" => "author",
          "title" => "Author",
          "type" => "reference",
          "to" => [%{"type" => @author}]
        }
      ]
    })

    upsert.("deskStructure", %{
      "singleton" => true,
      "visibility" => "private",
      "fields" => [%{"name" => "items", "title" => "Items", "type" => "array"}]
    })

    for i <- 1..3 do
      {:ok, _} =
        Content.create_document(
          @author,
          %{"doc_id" => "dlrc-author-#{i}", "title" => "Author #{i}"},
          dataset
        )
    end

    {:ok, _} = Content.publish_document("dlrc-author-1", @author, dataset)

    for i <- 1..130 do
      num = String.pad_leading(to_string(i), 3, "0")
      id = "dlrc-article-#{num}"

      {:ok, _} =
        Content.create_document(
          @article,
          %{
            "doc_id" => id,
            "title" => "Article #{num}",
            "content" => %{
              "category" => if(rem(i, 2) == 0, do: "news", else: "sport"),
              "author" => %{"_type" => "reference", "_ref" => "dlrc-author-#{rem(i, 3) + 1}"}
            }
          },
          dataset
        )

      if rem(i, 5) == 0, do: {:ok, _} = Content.publish_document(id, @article, dataset)
    end

    items = [
      %{"kind" => "documentTypeList", "id" => "articles", "type" => @article, "title" => "All"},
      %{
        "kind" => "list",
        "id" => "editorial",
        "title" => "Editorial",
        "items" => [
          %{
            "kind" => "list",
            "id" => "sections",
            "title" => "Sections",
            "items" => [
              %{
                "kind" => "documentTypeList",
                "id" => "news",
                "type" => @article,
                "title" => "News",
                "filter" => %{"content.category" => %{"eq" => "news"}},
                "orderings" => [%{"field" => "title", "direction" => "desc"}]
              }
            ]
          },
          %{
            "kind" => "documentTypeList",
            "id" => "authors",
            "type" => @author,
            "title" => "People"
          },
          %{
            "kind" => "tree",
            "id" => "article-tree",
            "type" => @article,
            "title" => "By parent",
            "parent" => "content.parent"
          },
          %{
            "kind" => "documentTypeList",
            "id" => "refused",
            "type" => @article,
            "title" => "Refused",
            "filter" => %{"content.category" => %{"near" => "news"}}
          }
        ]
      }
    ]

    {:ok, _} =
      Content.create_document(
        "deskStructure",
        %{"doc_id" => "deskStructure", "title" => "Desk", "content" => %{"items" => items}},
        dataset
      )

    {:ok, _} = Content.publish_document("deskStructure", "deskStructure", dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]

    # The tree as `DeskLive` holds it for the visit.
    root =
      dataset
      |> Structure.build([defer_group_by: true] ++ scope)
      |> StructureCopy.localize()
      |> Tree.normalize()

    {:ok, dataset: dataset, scope: scope, root: root}
  end

  # The Repo queries `fun` runs, in this process or a task it starts, each as
  # `{source, sql, params}`.
  defp queries(fun) do
    test = self()
    handler = "desk-list-read-cost-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:barkpark, :repo, :query],
        fn _event, _measure, meta, _config ->
          if self() == test or test in Process.get(:"$callers", []),
            do: send(test, {:dlrc_query, {meta[:source], meta[:query], meta[:params]}})
        end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, drain([])}
  end

  defp drain(acc) do
    receive do
      {:dlrc_query, query} -> drain([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The desk tree's own queries: what `PaneBuilder.build/3` reads before it
  # reaches the list (schema catalog, the declared desk document, plugin
  # enablement, the type census).
  defp tree_queries(%{dataset: dataset, scope: scope}) do
    {_tree, tree} =
      queries(fn ->
        dataset |> Structure.build([defer_group_by: true] ++ scope) |> StructureCopy.localize()
      end)

    assert tree != [], "building the desk tree must read something"
    tree
  end

  # One list pane of the URL `splat`, read as the pane reads it with the node
  # the page holds, beside the same list read by `PaneBuilder.build/3` for
  # its path (no node). Both with their queries.
  defp both(%{dataset: dataset, scope: scope, root: root}, splat, limit, sort \\ nil) do
    chain = Tree.parse(splat, root)
    index = length(chain) - 1
    pane = PaneComponent.with_query(List.last(chain), chain, index, limit, sort)
    assert pane.kind == :list, "#{splat} must open a list, got #{inspect(pane.kind)}"
    node = Tree.index(root)[pane.node]
    assert node, "the page holds the node of #{splat}"

    {read, read_q} = queries(fn -> PaneComponent.read_pane(pane, node, dataset, scope) end)
    {built, built_q} = queries(fn -> Rows.read(pane.type, pane.query, dataset, scope) end)
    assert built, "the old path must find #{splat}"
    {read, read_q, built, built_q}
  end

  # The read with a node runs none of the tree's queries, and exactly the
  # old path's queries without them.
  defp assert_no_tree_read(splat, read_q, built_q, tree_q) do
    in_tree = Enum.filter(read_q, &(&1 in tree_q))

    assert in_tree == [],
           "#{splat}: a list read with the page's node ran #{length(read_q)} queries, " <>
             "#{length(in_tree)} of them the desk tree's: #{inspect(Enum.map(in_tree, &elem(&1, 0)))}"

    assert Enum.sort(read_q) == Enum.sort(built_q -- tree_q),
           "#{splat}: the read ran #{length(read_q)} queries, the old path " <>
             "#{length(built_q)} of which #{length(tree_q)} build the tree"
  end

  defp shape(rows) do
    rows
    |> Map.take([:title, :more?, :sorts, :sort, :refused])
    |> Map.put(:entries, Enum.map(rows.entries, &Map.take(&1, [:title, :sub, :draft, :next])))
  end

  test "a top-level list reads no desk tree, and its rows are the built rows", ctx do
    tree_q = tree_queries(ctx)
    {read, read_q, built, built_q} = both(ctx, "articles", 100)

    assert_no_tree_read("articles", read_q, built_q, tree_q)
    assert shape(read) == shape(built)
    assert length(read.entries) == 100
    assert read.more? == true
    assert read.title == "All"
    assert hd(read.entries).title == "Article 001"
    assert hd(read.entries).sub == "Author 2"
  end

  test "a filtered list two menus deep, with a sort picked, reads no desk tree", ctx do
    tree_q = tree_queries(ctx)
    {read, read_q, built, built_q} = both(ctx, "editorial;sections;news", 1000, "titleDesc")

    assert_no_tree_read("editorial;sections;news", read_q, built_q, tree_q)
    assert shape(read) == shape(built)
    assert length(read.entries) == 65
    assert read.more? == false
    assert read.sort == "titleDesc"
    assert hd(read.entries).title == "Article 130"
    assert read.title == "News"
  end

  test "a declared order, another type, a tree root and a refused filter read as built", ctx do
    tree_q = tree_queries(ctx)

    for {splat, limit, check} <- [
          {"editorial;sections;news", 100,
           &(&1.sort == nil and hd(&1.entries).title == "Article 130")},
          {"editorial;authors", 100, &(&1.title == "People" and length(&1.entries) == 3)},
          {"editorial;article-tree", 100, &(length(&1.entries) == 100 and &1.more? == true)},
          {"editorial;refused", 100, &(is_binary(&1.refused) and &1.entries == [])}
        ] do
      {read, read_q, built, built_q} = both(ctx, splat, limit)

      assert_no_tree_read(splat, read_q, built_q, tree_q)
      assert shape(read) == shape(built), "#{splat}: the rows differ from the built rows"
      assert check.(read), "#{splat}: #{inspect(Map.delete(shape(read), :entries))}"
    end
  end

  test "a type name from an old link, with no node, still reads by its path", ctx do
    %{dataset: dataset, scope: scope} = ctx
    rows = Rows.read(@author, %{path: [@author], limit: 100, sort: nil}, dataset, scope)
    assert rows, "a type name from an old link must still read its rows"
    assert length(rows.entries) == 3
  end
end
