defmodule BarkparkWeb.Studio.Desk.TreeTest do
  use ExUnit.Case, async: true

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Tree

  defp desk do
    %Node{
      id: "root",
      type: :list,
      items: [
        %Node{id: "d0", type: :divider},
        %Node{id: "posts", type: :document_type_list, type_name: "post", title: "Posts"},
        %Node{id: "d1", type: :divider},
        %Node{id: "d2", type: :divider},
        %Node{
          id: "utgivelser",
          type: :list,
          title: "Utgivelser",
          items: [
            %Node{
              id: "uten-omslag",
              type: :document_type_list,
              type_name: "pub",
              filter: "cover=none"
            }
          ]
        },
        %Node{id: "settings", type: :document, type_name: "siteSettings", doc_id: "site"},
        %Node{id: "admin", type: :plugin_link, filter: "/admin"},
        %Node{id: "empty", type: :list, items: [%Node{id: "x", type: :plugin_link}]},
        %Node{id: "secret", type: :document_type_list, type_name: "secret", desk_hidden: true},
        %Node{id: "rest-gone", type: :document},
        %Node{id: "d3", type: :divider}
      ]
    }
  end

  test "normalize keeps what the slice can open and drops lists left empty" do
    ids = desk() |> Tree.normalize() |> Map.fetch!(:items) |> Enum.map(& &1.id)
    refute "admin" in ids
    refute "empty" in ids
    assert "utgivelser" in ids
  end

  test "rows drop hidden types and the dividers left leading, doubled or trailing" do
    rows = desk() |> Tree.normalize() |> Tree.rows() |> Enum.map(& &1.id)
    assert rows == ["posts", "d1", "utgivelser", "settings", "rest-gone"]
  end

  test "a row opens a menu, a list, a singleton, or nothing" do
    nodes = desk() |> Tree.normalize() |> Tree.index()

    assert Tree.opens(nodes["utgivelser"]) == %{kind: :menu, node: "utgivelser"}
    assert Tree.opens(nodes["posts"]) == %{kind: :list, type: "post", node: "posts"}

    assert Tree.opens(nodes["settings"]) ==
             %{kind: :doc, id: "site", type: "siteSettings", node: "settings"}

    assert Tree.opens(nodes["rest-gone"]) == nil
    assert Tree.opens(nodes["d1"]) == nil
  end

  test "a URL is read segment by segment against the desk, and prints back the same" do
    root = Tree.normalize(desk())

    assert Tree.parse(nil, root) == [%{kind: :types}]

    assert Tree.parse("utgivelser;uten-omslag;pub-1", root) == [
             %{kind: :types},
             %{kind: :menu, node: "utgivelser"},
             %{kind: :list, type: "pub", node: "uten-omslag"},
             %{kind: :doc, id: "pub-1", type: "pub"}
           ]

    assert Tree.parse("settings", root) == [
             %{kind: :types},
             %{kind: :doc, id: "site", type: "siteSettings", node: "settings"}
           ]

    for splat <- [
          "posts",
          "posts;post-01",
          "posts;post-01;author-alan,type=author,parentRefPath=author",
          "utgivelser",
          "utgivelser;uten-omslag;pub-1",
          "settings",
          "settings;post-01,type=post,parentRefPath=featured"
        ] do
      assert Panes.to_splat(Tree.parse(splat, root)) == splat
    end
  end

  test "a hidden type still resolves by direct URL" do
    root = Tree.normalize(desk())
    assert [_, %{kind: :list, type: "secret", node: "secret"}] = Tree.parse("secret", root)
  end

  test "a first segment that is no desk node reads as a plain type list" do
    root = Tree.normalize(desk())
    assert Tree.parse("post;post-01", root) == Panes.parse("post;post-01")
  end

  test "a row's href opens its pane right of the row's own pane and drops the rest" do
    root = Tree.normalize(desk())
    panes = Tree.parse("utgivelser;uten-omslag;pub-1", root)
    posts = Tree.opens(Tree.index(root)["posts"])

    assert Panes.open_after(panes, 0, posts, "/desk") == "/desk/posts"

    assert Panes.open_after(panes, 2, %{kind: :doc, id: "pub-2", type: "pub"}, "/desk") ==
             "/desk/utgivelser;uten-omslag;pub-2"
  end
end
