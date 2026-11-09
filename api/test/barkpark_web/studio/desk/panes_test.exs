defmodule BarkparkWeb.Studio.Desk.PanesTest do
  # The cases of `app/src/lib/panes.test.ts` in the TanStack Studio
  # (barkpark-studio), so both studios read and print one pane URL grammar.
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.Desk.Panes

  defp round_trip("/structure/" <> splat), do: Panes.to_path(Panes.parse(splat))

  @urls [
    "/structure/post;post-26",
    "/structure/post;post-26|,",
    "/structure/post;post-26|,view=json",
    "/structure/post;post-01;author-alan,type=author,parentRefPath=author",
    "/structure/post;post-01;author-alan,type=author,parentRefPath=author|,",
    "/structure/post;post-22,path=excerpt",
    "/structure/post;post-22,path=seo.metaTitle",
    "/structure/post;post-22;author-ada,type=author,parentRefPath=author,path=bio",
    "/structure/post;n1,template=post-by-author,eyJhdXRob3JJZCI6ImF1dGhvci1hZGEifQ",
    "/structure/category;n2,template=category"
  ]

  test "URLs round-trip: parse then print is identity" do
    for url <- @urls, do: assert(round_trip(url) == url)
  end

  test "panes round-trip: print then parse is identity" do
    for "/structure/" <> splat <- @urls do
      panes = Panes.parse(splat)
      assert Panes.parse(Panes.to_splat(panes)) == panes
    end
  end

  test "no segments is the root pane, and prints as the base path" do
    assert Panes.parse(nil) == [%{kind: :types}]
    assert Panes.parse("") == [%{kind: :types}]
    assert Panes.to_path([%{kind: :types}]) == "/structure"

    assert Panes.to_path(Panes.parse("post;post-26"), "/w/a/p/b/d/c/desk") ==
             "/w/a/p/b/d/c/desk/post;post-26"
  end

  test "split, open a ref from the left side, close the split" do
    one = Panes.parse("post;post-26")
    assert Panes.split_right(one, 2) == "/structure/post;post-26|,"

    two = Panes.parse("post;post-26|,")
    author = %{kind: :doc, id: "author-ada", type: "author", parent_ref_path: "author"}

    assert Panes.open_after(two, 2, author) ==
             "/structure/post;post-26|,;author-ada,type=author,parentRefPath=author"

    assert Panes.close_split(two, 3) == "/structure/post;post-26"
    assert Panes.close_split(two, 2) == "/structure/post;post-26"
    assert Panes.split?(two, 2) and Panes.split?(two, 3)
    refute Panes.split?(one, 2)
  end

  test "a focused field rides in the pane, nested paths included" do
    assert [_, _, %{path: "seo.metaTitle"}] = Panes.parse("post;post-22,path=seo.metaTitle")

    # A field inside an array item, as the router shows the URL (decoded) and as it encodes it.
    path = ~s(links[_key=="l1"].title)

    for splat <- ["post;post-03,path=" <> path, "post;post-03,path=" <> URI.encode_www_form(path)] do
      assert [_, _, %{path: ^path}] = Panes.parse(splat)
    end
  end

  test "with no desk, a singleton type opens its one doc, and prints back the same" do
    one = MapSet.new(["siteSettings"])

    assert Panes.parse_singleton("siteSettings", one) == [
             %{kind: :types},
             %{kind: :doc, id: "siteSettings", type: "siteSettings", node: "siteSettings"}
           ]

    for url <- [
          "/structure/siteSettings",
          "/structure/siteSettings,changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory",
          "/structure/siteSettings|,",
          "/structure/siteSettings;post-01,type=post,parentRefPath=featured"
        ] do
      "/structure/" <> splat = url
      assert Panes.to_path(Panes.parse_singleton(splat, one)) == url
    end

    assert Panes.parse_singleton("post;post-01", one) == Panes.parse("post;post-01")

    # A list-style link (search, Copy URL) is the same one doc, params kept.
    assert Panes.to_path(Panes.parse_singleton("siteSettings;siteSettings,view=json", one)) ==
             "/structure/siteSettings,view=json"

    # Opened from the root row: the URL is the type alone.
    settings = %{kind: :doc, id: "siteSettings", type: "siteSettings", node: "siteSettings"}
    assert Panes.open_after([%{kind: :types}], 0, settings) == "/structure/siteSettings"
  end

  test "inspectors in Sanity's names, so a link opens the same one in either studio" do
    inspect_of = fn splat -> Enum.at(Panes.parse(splat), 2)[:inspect] end

    # As Sanity writes them (the router shows them decoded), and ours from before.
    assert inspect_of.("post;post-01,inspect=sanity/structure/validation") == "validation"
    assert inspect_of.("post;post-01,inspect=sanity/comments") == "comments"

    assert inspect_of.(
             "post;post-01,since=@lastPublished,changesInspectorTab=review,inspect=sanity/structure/history"
           ) == "review"

    assert inspect_of.(
             "post;post-01,changesInspectorTab=history,inspect=sanity/structure/history"
           ) == "history"

    for old <- ~w(validation comments review history meta) do
      assert inspect_of.("post;post-01,inspect=" <> old) == old
    end

    # Printed in Sanity's form.
    assert round_trip("/structure/post;post-01,inspect=review") ==
             "/structure/post;post-01,since=@lastPublished,changesInspectorTab=review,inspect=sanity%2Fstructure%2Fhistory"

    assert round_trip("/structure/post;post-01,inspect=validation") ==
             "/structure/post;post-01,inspect=sanity%2Fstructure%2Fvalidation"

    assert round_trip("/structure/post;post-01,inspect=sanity%2Fstructure%2Fincoming-references") ==
             "/structure/post;post-01,inspect=sanity%2Fstructure%2Fincoming-references"
  end

  test "a followed doc without type= is marked for a type lookup; the first doc and split siblings are not" do
    [_, _, first, next] = Panes.parse("post;post-01;author-alan")
    refute Map.has_key?(first, :untyped)
    assert next.untyped == true

    refute Map.has_key?(Enum.at(Panes.parse("post;post-01;author-alan,type=author"), 3), :untyped)
    refute Map.has_key?(Enum.at(Panes.parse("post;post-01|,"), 3), :untyped)
  end

  test "a new doc names its template and parameters, as Sanity writes them" do
    sanity = "post;n1,template=post-by-author,eyJhdXRob3JJZCI6ImF1dGhvci1hZGEifQ"

    assert Enum.at(Panes.parse(sanity), 2) == %{
             kind: :doc,
             id: "n1",
             type: "post",
             template: "post-by-author",
             template_params: %{"authorId" => "author-ada"}
           }

    # Padded base64 reads the same.
    assert Enum.at(Panes.parse(sanity <> "=="), 2).template_params == %{
             "authorId" => "author-ada"
           }
  end

  test "view, params and closing change one pane and keep the rest" do
    panes = Panes.parse("post;post-01;author-alan,type=author,parentRefPath=author")

    assert Panes.with_view(panes, 2, "json") ==
             "/structure/post;post-01,view=json;author-alan,type=author,parentRefPath=author"

    assert Panes.with_view(Panes.parse("post;post-01,view=json"), 2, "") ==
             "/structure/post;post-01"

    assert Panes.with_params(panes, 2, %{rev: "r1", path: "title"}) ==
             "/structure/post;post-01,rev=r1,path=title;author-alan,type=author,parentRefPath=author"

    assert Panes.with_params(Panes.parse("post;post-01,rev=r1"), 2, %{rev: nil}) ==
             "/structure/post;post-01"

    assert Panes.close_from(panes, 3) == "/structure/post;post-01"
    assert Panes.close_from(panes, 1) == "/structure"
  end

  test "pane keys name the pane" do
    assert Enum.map(Panes.parse("post;post-01"), &Panes.pane_key/1) == [
             "types",
             "list:post",
             "doc:post-01"
           ]

    assert Panes.pane_key(%{kind: :menu, node: "utgivelser"}) == "menu:utgivelser"

    assert Panes.pane_key(%{kind: :list, type: "category", node: "tree", tree_parent: "c1"}) ==
             "list:category:tree:c1"
  end
end
