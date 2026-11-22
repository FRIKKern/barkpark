defmodule BarkparkWeb.Studio.StoredNullSubfieldTest do
  @moduledoc """
  A stored JSON null inside an object or an array row is data: an edit of
  a sibling, or a pick in a sibling's tree, keeps it byte-identical, in the
  desk and in the old Studio. The form buffer holds the stored object, nulls
  included, so a null in a post is not the desk's unset (`Forms.unset/0`).
  Review of #27740 r2: the unset hunk took a stored null off on such edits.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "onixedit:null-sub-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "Null sub",
        values: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction"}],
            children:
              for(
                i <- 1..101,
                do: %{code: "FB#{i}", translations: [%{language: "eng", label: "F#{i}"}]}
              )
          }
        ]
      })

    type = "ns_book_#{n}"
    tree = %{"type" => "codelist", "codelistId" => list_id}
    text = fn name -> %{"name" => name, "title" => String.upcase(name), "type" => "string"} end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Null sub",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "zn",
              "title" => "Zn",
              "type" => "composite",
              "fields" => [
                Map.merge(tree, %{"name" => "c", "title" => "C"}),
                text.("label"),
                text.("s")
              ]
            },
            %{
              "name" => "outer",
              "title" => "Outer",
              "type" => "composite",
              "fields" => [
                %{
                  "name" => "inner",
                  "title" => "Inner",
                  "type" => "composite",
                  "fields" => [text.("label"), text.("s")]
                }
              ]
            },
            %{
              "name" => "rows",
              "title" => "Rows",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [
                  Map.merge(tree, %{"name" => "rc", "title" => "RC"}),
                  text.("rl"),
                  text.("rs")
                ]
              }
            },
            %{"name" => "notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "null-sub-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "null-sub", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type}
  end

  @content %{
    "zn" => %{"c" => "FB1", "label" => nil, "s" => "a"},
    "outer" => %{"inner" => %{"label" => nil, "s" => "a"}},
    "rows" => [%{"_key" => "r1", "rc" => "FB1", "rl" => nil, "rs" => "a"}],
    "notes" => "0"
  }

  defp doc!(c) do
    id = "ns-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => @content},
        @dataset
      )

    id
  end

  defp open(c, :desk, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    {view, "[data-pane-editing] #editor-form"}
  end

  defp open(c, :studio, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/#{c.type}/#{id}")
    assert has_element?(view, "#editor-form")
    {view, "#editor-form"}
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp type_in(view, form, name, value) do
    view |> form(form, %{name => value}) |> render_change(%{"_target" => [name]})
  end

  defp pick(view, form, tree, code) do
    tree = "#{form} ##{tree}"
    node = tree <> ~s( [phx-click="tree_node_select"][phx-value-code="#{code}"])

    unless has_element?(view, node) do
      view
      |> element(tree <> ~s( [phx-click="tree_node_toggle"][phx-value-code="FB"]))
      |> render_click()
    end

    EditorPost.press_on(view, element(view, node))
    render(view)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: a sibling's edit keeps a stored null in an object, a nested object and a row",
         c do
      id = doc!(c)
      {view, form} = open(c, @surface, id)

      type_in(view, form, "doc[zn].s", "b")
      assert stored(c, id)["zn"] == %{"c" => "FB1", "label" => nil, "s" => "b"}

      type_in(view, form, "doc[outer].inner.s", "b")
      assert stored(c, id)["outer"] == %{"inner" => %{"label" => nil, "s" => "b"}}

      type_in(view, form, "doc[rows][0].rs", "b")
      assert stored(c, id)["rows"] == [%{"_key" => "r1", "rc" => "FB1", "rl" => nil, "rs" => "b"}]

      type_in(view, form, "doc[notes]", "typed")

      assert Map.delete(stored(c, id), "notes") |> Map.take(["zn", "outer", "rows"]) ==
               %{
                 "zn" => %{"c" => "FB1", "label" => nil, "s" => "b"},
                 "outer" => %{"inner" => %{"label" => nil, "s" => "b"}},
                 "rows" => [%{"_key" => "r1", "rc" => "FB1", "rl" => nil, "rs" => "b"}]
               }
    end

    test "#{surface}: a pick in a sibling tree keeps a stored null, in an object and a row", c do
      id = doc!(c)
      {view, form} = open(c, @surface, id)

      pick(view, form, "tree-f-zn-c", "FB2")
      assert stored(c, id)["zn"] == %{"c" => "FB2", "label" => nil, "s" => "a"}

      pick(view, form, "tree-f-rows-0-rc", "FB3")
      assert stored(c, id)["rows"] == [%{"_key" => "r1", "rc" => "FB3", "rl" => nil, "rs" => "a"}]
    end
  end
end
