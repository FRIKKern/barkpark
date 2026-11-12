defmodule BarkparkWeb.Studio.Desk.TreeTest do
  use ExUnit.Case, async: true

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.Desk.Panes
  alias BarkparkWeb.Studio.Desk.Tree

  @types %{kind: :types}

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

  test "a segment that is not under its desk list opens a pane that says so" do
    root = Tree.normalize(desk())
    nodes = Tree.index(root)

    # "nope" is nowhere on the desk. "posts" (a type list), "settings" (a
    # singleton), "root" and "utgivelser" itself are on it, but not under
    # "utgivelser": the pane must not draw them there.
    for id <- ~w(nope posts settings root utgivelser) do
      panes = Tree.parse("utgivelser;#{id};pub-1", root)

      assert panes == [
               %{kind: :types},
               %{kind: :menu, node: "utgivelser"},
               %{kind: :menu, node: id, missing: true}
             ]

      # No node, so the pane draws "This list is not on the desk." and no rows.
      missing = List.last(panes)
      assert Tree.node_of(missing, root, nodes) == nil, id
      # Not the pane of the real list of that id: it shares no state with it.
      refute Panes.pane_key(missing) == Panes.pane_key(%{kind: :menu, node: id}), id
      # The URL keeps the segment as it was typed.
      assert Panes.to_path(panes, "/d") == "/d/utgivelser;#{id}"
    end

    # A list that is under its parent still draws its own node.
    [types, menu, list] = Tree.parse("utgivelser;uten-omslag", root)
    assert Tree.node_of(types, root, nodes) == root
    assert Tree.node_of(menu, root, nodes) == nodes["utgivelser"]
    assert Tree.node_of(list, root, nodes) == nodes["uten-omslag"]

    assert Tree.node_of(
             %{kind: :doc, id: "site", type: "siteSettings", node: "settings"},
             root,
             nodes
           ) == nil
  end

  test "a list id used in two menus: each pane draws the node under its own menu" do
    list = fn filter ->
      %Node{id: "nyheter", type: :document_type_list, type_name: "post", filter: filter}
    end

    root =
      %Node{
        id: "root",
        type: :list,
        items: [
          %Node{id: "norsk", type: :list, title: "Norsk", items: [list.("lang=nb")]},
          %Node{id: "svensk", type: :list, title: "Svensk", items: [list.("lang=sv")]}
        ]
      }
      |> Tree.normalize()

    # The flat index keeps one of the two; the chain knows which it means.
    nodes = Tree.index(root)

    for {menu, filter} <- [{"norsk", "lang=nb"}, {"svensk", "lang=sv"}] do
      panes = Tree.parse("#{menu};nyheter;post-1", root)
      [types, open_menu, open_list, doc] = Tree.nodes_of(panes, root, nodes)

      assert types == root
      assert open_menu.id == menu
      assert open_list.filter == filter, menu
      assert doc == nil
    end
  end

  # ── desk.test.ts in the TanStack Studio (barkpark-studio) ─────────────────
  #
  # Its fixture, the Agency twin cut down, as `Barkpark.Structure.build/2`
  # gives it. Ported: every test about which panes a URL opens. Left out,
  # because the Phoenix desk does them elsewhere and they are no pane URL:
  #   * "filters, tree levels, ops the query API lacks, and orderings" —
  #     listFilter, unsupportedOps, deskSort build the list query;
  #     PaneBuilder reads it (tree_level_filter/3, desk_order/3).
  #   * "a desk filter with neqOrMissing", "a tree's own filter narrows every
  #     level", "a tree over an array of parents drills with has" (the
  #     filter half), "a desk filter with an $or group", "a Barkpark without
  #     $or groups gets the advisory" — list filters and the server's 400,
  #     PaneBuilder and Content.Query.
  #   * "J18: a child list opens the docs that point at the row" — `child`
  #     lists come from the TanStack Studio's own config; Barkpark's desk has
  #     no such node.
  #   * "B12, owner's call: a declared desk is shown exactly" — rootDesk
  #     picks between a declared desk and the TanStack config's items; the
  #     Phoenix desk has only Structure.build/2.
  #   * paneTitleOf and newDocPreset in "a declared list's paneTitle" and "a
  #     declared list's initialValues" — PaneComponent.provisional_title/2
  #     and PaneBuilder; only their "normalizeDesk keeps it" half is here.
  defp twin_desk do
    Tree.normalize(%Node{
      id: "root",
      type: :list,
      items: [
        %Node{
          id: "forside",
          type: :document,
          title: "Forside",
          type_name: "frontpage",
          doc_id: "frontpage"
        },
        %Node{id: "desk-1", type: :divider},
        %Node{
          id: "utgivelser",
          type: :list,
          title: "Utgivelser",
          items: [
            %Node{
              id: "alle-utgivelser",
              type: :document_type_list,
              type_name: "publication",
              orderings: [%{"field" => "title", "direction" => "asc"}]
            },
            %Node{
              id: "uten-omslag",
              type: :document_type_list,
              type_name: "publication",
              filter: %{"content.cover.assetId" => %{"is" => "null"}}
            }
          ]
        },
        %Node{
          id: "kategorier",
          type: :list,
          items: [
            %Node{
              id: "hierarkisk-struktur",
              type: :document_type_list,
              type_name: "category",
              tree: %{"parent" => "content.parent"},
              filter: %{"content.parent" => %{"is" => "null"}}
            },
            %Node{
              id: "uten-utgivelser",
              type: :document_type_list,
              type_name: "category",
              filter: %{"_id" => %{"notReferencedBy" => "publication"}}
            }
          ]
        },
        %Node{id: "desk-9", type: :divider},
        %Node{id: "plugin-link-1", type: :plugin_link, title: "Fleet", filter: "/admin/fleet"},
        %Node{
          id: "plugins",
          type: :list,
          title: "Plugins",
          items: [
            %Node{
              id: "plugin-grp-quiz",
              type: :list,
              items: [%Node{id: "q", type: :plugin_document_list}]
            }
          ]
        }
      ]
    })
  end

  defp twin_round(splat), do: Panes.to_splat(Tree.parse(splat, twin_desk()))

  @menu_kat %{kind: :menu, node: "kategorier"}
  @tree_root %{kind: :list, type: "category", node: "hierarkisk-struktur"}
  defp level(parent), do: Map.put(@tree_root, :tree_parent, parent)

  test "desk URLs round-trip" do
    for splat <- [
          "forside",
          "forside|,view=json",
          "utgivelser",
          "utgivelser;uten-omslag",
          "utgivelser;alle-utgivelser;pub-1",
          "utgivelser;alle-utgivelser;pub-1;author-1,type=author,parentRefPath=author",
          "kategorier;hierarkisk-struktur;cat-1",
          "kategorier;hierarkisk-struktur;cat-1;cat-2",
          "kategorier;hierarkisk-struktur;cat-1;cat-2;cat-2"
        ] do
      assert {splat, twin_round(splat)} == {splat, splat}
    end
  end

  test "desk URLs open the same panes as parseDeskPanes" do
    pub = %{kind: :list, type: "publication", node: "alle-utgivelser"}
    utg = %{kind: :menu, node: "utgivelser"}
    front = %{kind: :doc, id: "frontpage", type: "frontpage"}

    for {splat, panes} <- [
          {"forside", [@types, Map.put(front, :node, "forside")]},
          {"forside|,view=json",
           [
             @types,
             Map.put(front, :node, "forside"),
             Map.merge(front, %{sibling: true, view: "json"})
           ]},
          {"utgivelser", [@types, utg]},
          {"utgivelser;uten-omslag",
           [@types, utg, %{kind: :list, type: "publication", node: "uten-omslag"}]},
          {"utgivelser;alle-utgivelser;pub-1",
           [@types, utg, pub, %{kind: :doc, id: "pub-1", type: "publication"}]},
          {"utgivelser;alle-utgivelser;pub-1;author-1,type=author,parentRefPath=author",
           [
             @types,
             utg,
             pub,
             %{kind: :doc, id: "pub-1", type: "publication"},
             %{kind: :doc, id: "author-1", type: "author", parent_ref_path: "author"}
           ]},
          {"kategorier;hierarkisk-struktur;cat-1",
           [@types, @menu_kat, @tree_root, level("cat-1")]},
          {"kategorier;hierarkisk-struktur;cat-1;cat-2",
           [@types, @menu_kat, @tree_root, level("cat-1"), level("cat-2")]},
          {"kategorier;hierarkisk-struktur;cat-1;cat-2;cat-2",
           [
             @types,
             @menu_kat,
             @tree_root,
             level("cat-1"),
             level("cat-2"),
             %{kind: :doc, id: "cat-2", type: "category"}
           ]}
        ] do
      assert {splat, Tree.parse(splat, twin_desk())} == {splat, panes}
    end
  end

  test "a singleton segment opens its pinned doc" do
    assert [_, doc] = Tree.parse("forside", twin_desk())
    assert doc == %{kind: :doc, id: "frontpage", type: "frontpage", node: "forside"}
  end

  test "in a tree, an id opens its children and the same id again opens the doc" do
    panes = Tree.parse("kategorier;hierarkisk-struktur;cat-1;cat-1", twin_desk())
    assert Enum.map(panes, & &1.kind) == [:types, :menu, :list, :list, :doc]
    assert Enum.at(panes, 3).tree_parent == "cat-1"
    assert Enum.at(panes, 4).id == "cat-1"
  end

  test "a type name or unknown first segment reads as before (search, old links)" do
    kinds = "publication;pub-1" |> Tree.parse(twin_desk()) |> Enum.map(& &1.kind)
    assert kinds == [:types, :list, :doc]
  end

  test "plugin links and the dividers they leave go" do
    assert twin_desk() |> Tree.rows() |> Enum.map(& &1.id) == [
             "forside",
             "desk-1",
             "utgivelser",
             "kategorier"
           ]
  end

  test "normalize keeps a list's pane title and a type list's initial values" do
    landing = %Node{
      id: "landingssider",
      type: :document_type_list,
      type_name: "page",
      initial_values: %{"pageType" => "landingPage"},
      pane_title: "Produkter med anmeldelser"
    }

    root =
      Tree.normalize(%Node{
        id: "root",
        type: :list,
        items: [%Node{id: "u", type: :list, pane_title: "Alle utgivelser", items: [landing]}]
      })

    assert [%Node{pane_title: "Alle utgivelser", items: [kept]}] = root.items
    assert kept.pane_title == "Produkter med anmeldelser"
    assert kept.initial_values == %{"pageType" => "landingPage"}
  end

  # ── beyond desk.test.ts: the same grammar, more of the desk ───────────────

  test "a tree level carries what it lists: the tree node and the parent id" do
    panes = Tree.parse("kategorier;hierarkisk-struktur;cat-1", twin_desk())
    assert List.last(panes) == level("cat-1")
    assert Panes.pane_key(List.last(panes)) == "list:category:hierarkisk-struktur:cat-1"
  end

  test "a tree over an array of parents drills the same way" do
    root = %Node{
      id: "root",
      type: :list,
      items: [
        %Node{
          id: "kat",
          type: :document_type_list,
          type_name: "category",
          filter: %{"content.parentCategories" => %{"countEq" => 0}},
          tree: %{"parent" => "content.parentCategories", "op" => "has"}
        }
      ]
    }

    assert Tree.parse("kat;c-root;c-root", root) == [
             @types,
             %{kind: :list, type: "category", node: "kat"},
             %{kind: :list, type: "category", node: "kat", tree_parent: "c-root"},
             %{kind: :doc, id: "c-root", type: "category"}
           ]
  end

  test "a tree's doc keeps its params and what follows it" do
    for splat <- [
          "kategorier;hierarkisk-struktur;cat-1;cat-1,view=json",
          "kategorier;hierarkisk-struktur;cat-1;cat-1,path=title",
          "kategorier;hierarkisk-struktur;cat-1;cat-1,rev=r1",
          "kategorier;hierarkisk-struktur;cat-1;cat-1,inspect=sanity%2Fstructure%2Fvalidation",
          "kategorier;hierarkisk-struktur;cat-1;cat-1|,",
          "kategorier;hierarkisk-struktur;cat-1;cat-1;pub-1,type=publication,parentRefPath=parent"
        ] do
      assert {splat, twin_round(splat)} == {splat, splat}
    end

    assert [_, _, _, _, %{kind: :doc, id: "cat-1", path: "title"}] =
             Tree.parse("kategorier;hierarkisk-struktur;cat-1;cat-1,path=title", twin_desk())
  end

  test "view, inspect, rev and path ride on desk docs and singletons" do
    for splat <- [
          "utgivelser;alle-utgivelser;pub-1,view=json",
          "utgivelser;alle-utgivelser;pub-1,since=@lastPublished,changesInspectorTab=review,inspect=sanity%2Fstructure%2Fhistory",
          "utgivelser;alle-utgivelser;pub-1,rev=r1,path=seo.metaTitle",
          "forside,view=json",
          "forside,changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory",
          "forside,path=title"
        ] do
      assert {splat, twin_round(splat)} == {splat, splat}
    end

    assert [_, %{kind: :doc, id: "frontpage", inspect: "history", node: "forside"}] =
             Tree.parse(
               "forside,changesInspectorTab=history,inspect=sanity/structure/history",
               twin_desk()
             )
  end

  # A groupBy the Phoenix desk builds with `defer_group_by: true` has no
  # children until a pane opens it (Structure.expand/3). Its children are
  # type lists with ids `<idx>-<key>`, one per `over` document.
  defp grouped_desk do
    item = %{
      "kind" => "groupBy",
      "id" => "etter-kategori",
      "type" => "publication",
      "by" => "content.category",
      "over" => "category"
    }

    Tree.normalize(%Node{
      id: "root",
      type: :list,
      items: [
        %Node{
          id: "etter-kategori",
          type: :list,
          title: "Etter kategori",
          items: [],
          deferred: {:group_by, item, 2}
        }
      ]
    })
  end

  test "a deferred groupBy stays on the desk and opens as a menu" do
    root = grouped_desk()
    assert [%Node{id: "etter-kategori"} = group] = Tree.rows(root)
    assert Tree.opens(group) == %{kind: :menu, node: "etter-kategori"}
    assert Tree.parse("etter-kategori", root) == [@types, %{kind: :menu, node: "etter-kategori"}]
  end

  test "a group of a deferred groupBy opens a list of the grouped type, then its docs" do
    root = grouped_desk()

    assert Tree.parse("etter-kategori;2-cat-1;pub-1", root) == [
             @types,
             %{kind: :menu, node: "etter-kategori"},
             %{kind: :list, type: "publication", node: "2-cat-1"},
             %{kind: :doc, id: "pub-1", type: "publication"}
           ]

    for splat <- ["etter-kategori;2-cat-1", "etter-kategori;2-cat-1;pub-1,view=json"] do
      assert {splat, Panes.to_splat(Tree.parse(splat, root))} == {splat, splat}
    end

    # An id the group never builds is not under it: a pane that says so.
    assert Tree.parse("etter-kategori;cat-1", root) == [
             @types,
             %{kind: :menu, node: "etter-kategori"},
             %{kind: :menu, node: "cat-1", missing: true}
           ]
  end

  # ── what the page asks the Studio for (PaneBuilder paths) ─────────────────

  test "the Studio path names each list's node, and a tree level its parent" do
    chain = Tree.parse("kategorier;hierarkisk-struktur;cat-1;cat-2;cat-2", twin_desk())

    assert Tree.studio_path(chain, 2) == ["kategorier", "hierarkisk-struktur"]
    assert Tree.studio_path(chain, 3) == ["kategorier", "hierarkisk-struktur", "cat-1"]
    assert Tree.studio_path(chain, 4) == ["kategorier", "hierarkisk-struktur", "cat-1", "cat-2"]

    plain = Tree.parse("utgivelser;alle-utgivelser;pub-1", twin_desk())
    assert Tree.studio_path(plain, 2) == ["utgivelser", "alle-utgivelser"]
    assert Tree.studio_path(Panes.parse("post;p-1"), 1) == ["post"]
  end

  test "a doc on top of a tree level is edited at the chain's path, the id twice" do
    edit = fn splat -> splat |> Tree.parse(twin_desk()) |> Tree.edit_path(twin_desk()) end

    assert edit.("kategorier;hierarkisk-struktur;cat-1;cat-1") ==
             ["kategorier", "hierarkisk-struktur", "cat-1", "cat-1"]

    assert edit.("kategorier;hierarkisk-struktur;cat-1;cat-2;cat-2") ==
             ["kategorier", "hierarkisk-struktur", "cat-1", "cat-2", "cat-2"]

    # Its split sibling is the same document.
    assert edit.("kategorier;hierarkisk-struktur;cat-1;cat-1|,view=json") ==
             ["kategorier", "hierarkisk-struktur", "cat-1", "cat-1"]

    # Not under a tree: the desk's list of its type, as before; a singleton its node.
    assert edit.("utgivelser;alle-utgivelser;pub-1") == ["utgivelser", "alle-utgivelser", "pub-1"]
    assert edit.("forside") == ["forside"]
    assert edit.("post;p-1") == ["post", "p-1"]
  end

  test "a doc of a tree's type opened from elsewhere is edited under its tree, the id twice" do
    root = twin_desk()

    assert Tree.doc_path(root, "category", "cat-9") ==
             ["kategorier", "hierarkisk-struktur", "cat-9", "cat-9"]

    assert Tree.doc_path(root, "publication", "pub-1") ==
             ["utgivelser", "alle-utgivelser", "pub-1"]

    assert Tree.doc_path(root, "nowhere", "x-1") == ["nowhere", "x-1"]

    chain =
      Tree.parse(
        "utgivelser;alle-utgivelser;pub-1;cat-9,type=category,parentRefPath=category",
        root
      )

    assert Tree.edit_path(chain, root) == ["kategorier", "hierarkisk-struktur", "cat-9", "cat-9"]
  end

  test "a tree list's row opens its children; the level's parent on top opens its doc" do
    nodes = Tree.index(twin_desk())
    tree = nodes["hierarkisk-struktur"]
    doc = fn id -> %{kind: :doc, id: id, type: "category"} end

    assert Tree.row_opens(@tree_root, tree, doc.("cat-1")) == level("cat-1")
    assert Tree.row_opens(level("cat-1"), tree, doc.("cat-1")) == doc.("cat-1")
    assert Tree.row_opens(level("cat-1"), tree, doc.("cat-2")) == level("cat-2")

    # Any other list's rows open their documents.
    pub = %{kind: :list, type: "publication", node: "alle-utgivelser"}
    next = %{kind: :doc, id: "pub-1", type: "publication"}
    assert Tree.row_opens(pub, nodes["alle-utgivelser"], next) == next
    assert Tree.row_opens(pub, nil, next) == next

    read = %{title: "Cat 1", entries: [%{title: "Cat 1", next: doc.("cat-1")}, :divider]}

    assert %{entries: [%{next: %{kind: :doc}}, :divider]} =
             Tree.tree_rows(read, level("cat-1"), tree)

    assert %{entries: [%{next: %{kind: :list, tree_parent: "cat-1"}}, :divider]} =
             Tree.tree_rows(read, @tree_root, tree)
  end

  test "a row's href opens its pane right of the row's own pane and drops the rest" do
    root = Tree.normalize(desk())
    panes = Tree.parse("utgivelser;uten-omslag;pub-1", root)
    posts = Tree.opens(Tree.index(root)["posts"])

    assert Panes.open_after(panes, 0, posts, "/desk") == "/desk/posts"

    assert Panes.open_after(panes, 2, %{kind: :doc, id: "pub-2", type: "pub"}, "/desk") ==
             "/desk/utgivelser;uten-omslag;pub-2"
  end

  # B13: Barkpark's desk puts the `singleton: true` types in a "Settings"
  # list (`Barkpark.Structure`); the TanStack Studio's root draws them in
  # place, under a "Settings" divider, each opening its one document.
  describe "a root list of singletons" do
    defp with_settings do
      %Node{
        id: "root",
        type: :list,
        items: [
          %Node{id: "posts", type: :document_type_list, type_name: "post", title: "Posts"},
          %Node{id: "div-4", type: :divider},
          %Node{
            id: "settings",
            type: :list,
            title: "Settings",
            items: [
              %Node{
                id: "siteSettings",
                type: :document,
                type_name: "siteSettings",
                title: "Site settings"
              },
              %Node{
                id: "navigation",
                type: :document,
                type_name: "navigation",
                title: "Navigation"
              }
            ]
          },
          %Node{id: "div-5", type: :divider},
          %Node{
            id: "rest",
            type: :list,
            title: "…Rest",
            items: [%Node{id: "rest-tag", type: :document, type_name: "tag", title: "tag (2)"}]
          }
        ]
      }
    end

    test "is drawn in place: its title a divider, its documents rows" do
      rows = with_settings() |> Tree.normalize() |> Tree.rows()

      assert Enum.map(rows, &{&1.type, &1.id, &1.title}) == [
               {:document_type_list, "posts", "Posts"},
               {:divider, "settings", "Settings"},
               {:document, "siteSettings", "Site settings"},
               {:document, "navigation", "Navigation"},
               {:divider, "div-5", nil},
               {:list, "rest", "…Rest"}
             ]
    end

    test "a singleton opens by its own segment, as the TanStack Studio's" do
      root = Tree.normalize(with_settings())
      doc = %{kind: :doc, id: "siteSettings", type: "siteSettings", node: "siteSettings"}

      assert Tree.parse("siteSettings", root) == [@types, doc]
      assert Tree.opens(Tree.index(root)["siteSettings"]) == doc
      assert Panes.open_after([@types], 0, doc, "/desk") == "/desk/siteSettings"
    end

    test "an old link through the list opens the same" do
      root = Tree.normalize(with_settings())
      doc = %{kind: :doc, id: "siteSettings", type: "siteSettings", node: "siteSettings"}

      assert Tree.parse("settings;siteSettings", root) == [@types, doc]
      assert Tree.parse("settings", root) == [@types]
    end

    test "only a list of singletons: a list holding anything else stays a list" do
      rows = with_settings() |> Tree.normalize() |> Tree.rows() |> Enum.map(& &1.id)
      assert "rest" in rows
      refute "rest-tag" in rows

      nested = %Node{id: "root", type: :list, items: [%Node{with_settings() | id: "inner"}]}
      assert nested |> Tree.normalize() |> Tree.rows() |> Enum.map(& &1.id) == ["inner"]
    end
  end
end
