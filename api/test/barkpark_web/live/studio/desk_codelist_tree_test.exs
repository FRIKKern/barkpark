defmodule BarkparkWeb.Studio.DeskCodelistTreeTest do
  @moduledoc """
  B05 (codelist.spec:6): the desk's tree codelist is the TanStack Studio's
  `TreePicker` (barkpark-studio `app/src/components/CodelistInput.tsx`).

  On main the desk drew the old Studio's tree: the search box answered only
  a key going up (`phx-keyup`), so a value put in the box without keys (the
  spec's `fill`, a paste from the menu) found nothing; its rows were buttons
  in `li`s, the tree had no name, and its search box no name of its own. A
  pick wrote into whatever document the editor held when it arrived.

  These tests drive the component's own events and read the store.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @plugin "onixedit"
  @form "[data-pane-editing] #editor-form"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    list_id = "#{@plugin}:desk-tree-#{n}"
    type = "dct_#{n}"

    # Over the tree threshold (100 raw values): the tree variant. Over 200
    # codes hold an F, for the search's limit.
    fillers =
      for i <- 1..210,
          do: %{code: "FBZ#{i}", translations: [%{language: "eng", label: "Filler #{i}"}]}

    {:ok, _} =
      Codelists.register(@plugin, list_id, %{
        issue: "1",
        name: "Thema subjects",
        values: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction"}],
            children: [
              %{code: "FBA", translations: [%{language: "eng", label: "Modern fiction"}]}
              | fillers
            ]
          },
          %{
            code: "Y",
            translations: [%{language: "eng", label: "Children"}],
            children: [
              %{code: "YFB", translations: [%{language: "eng", label: "Children's fiction"}]}
            ]
          }
        ]
      })

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Codelist #{type}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "subject",
              "title" => "Subject (Thema)",
              "type" => "codelist",
              "codelistId" => list_id
            },
            %{
              "name" => "audience",
              "title" => "Audience (Thema)",
              "type" => "codelist",
              "codelistId" => list_id
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    docs = %{
      code: {"dct-#{n}", %{"subject" => "FBA"}},
      none: {"dct-none-#{n}", %{}},
      int: {"dct-int-#{n}", %{"subject" => 7}},
      obj: {"dct-obj-#{n}", %{"subject" => %{"code" => "FBA"}}}
    }

    for {_k, {id, content}} <- docs do
      {:ok, _} =
        Content.create_document(
          type,
          Map.merge(%{"doc_id" => id, "title" => id}, content),
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-tree-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-tree", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok, conn: conn, root: root, type: type, docs: Map.new(docs, fn {k, {id, _}} -> {k, id} end)}
  end

  defp desk(c, key) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{c.docs[key]}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp content(c, key) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.docs[key], @dataset)
    doc.content || %{}
  end

  defp tree(field \\ "subject"),
    do: @form <> ~s( .codelist-tree-field[data-field-name="#{field}"])

  defp row(code, field \\ "subject"),
    do: tree(field) <> ~s( [role="treeitem"][data-code="#{code}"])

  # Text typed in a tree's search box, posted as the browser posts it: a
  # change on an input in a form sends the form's inputs of that name, so
  # every box in the form whose name is the typed box's rides along, and the
  # server reads them as Plug parses the body.
  defp search(view, text, field \\ "subject") do
    box = tree(field) <> ~s( input[type="search"])

    typed = view |> element(box) |> render() |> LazyHTML.from_fragment()
    [typed_name] = LazyHTML.attribute(typed, "name")
    [typed_id] = LazyHTML.attribute(typed, "id")

    body =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(@form <> ~s( .codelist-tree-field input[type="search"]))
      |> Enum.map(fn input ->
        [name] = LazyHTML.attribute(input, "name")
        [id] = LazyHTML.attribute(input, "id")

        {name,
         if(id == typed_id,
           do: text,
           else: input |> LazyHTML.attribute("value") |> List.first("")
         )}
      end)
      |> Enum.filter(fn {name, _} -> name == typed_name end)
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()

    view |> element(box) |> render_change(body)
  end

  # A row's click, named for the open document as the page's script names it.
  defp pick(view, code), do: EditorPost.press_on(view, element(view, row(code))) && render(view)

  test "the tree, its rows and its search box carry the TanStack Studio's roles and names", c do
    view = desk(c, :code)

    assert has_element?(
             view,
             tree() <> ~s( ul.codelist-tree[role="tree"][aria-label="Thema subjects"])
           )

    assert has_element?(
             view,
             tree() <>
               ~s| .codelist-search input.input[type="search"][aria-label="Subject (Thema)"][placeholder="Search codes or labels…"]|
           )

    # The picked code's branch is open; one row is in the Tab order.
    assert has_element?(
             view,
             row("FB") <> ~s([aria-level="1"][aria-expanded="true"][tabindex="0"])
           )

    assert has_element?(
             view,
             row("FBA") <> ~s([aria-level="2"][aria-selected="true"][tabindex="-1"])
           )

    assert has_element?(view, row("Y") <> ~s([aria-expanded="false"][aria-selected="false"]))
    refute has_element?(view, row("YFB"))
    refute has_element?(view, row("FBA") <> "[aria-expanded]")
    assert has_element?(view, row("FBA") <> " .mono", "FBA")
    assert has_element?(view, row("FBA") <> ~s( .codelist-toggle[aria-hidden="true"]))

    assert has_element?(view, tree() <> " .codelist-current .mono", "FBA")

    assert has_element?(
             view,
             tree() <> " .codelist-current .codelist-label",
             "Fiction › Modern fiction"
           )

    assert has_element?(
             view,
             tree() <> ~s( .codelist-current button.icon-btn[aria-label="Remove code"])
           )
  end

  test "a branch's ▶ opens and closes it", c do
    view = desk(c, :none)
    refute has_element?(view, row("YFB"))

    view |> element(row("Y") <> " .codelist-toggle") |> render_click()
    assert has_element?(view, row("Y") <> ~s([aria-expanded="true"]))
    assert has_element?(view, row("YFB") <> ~s([aria-level="2"][data-parent="Y"]))

    view |> element(row("Y") <> " .codelist-toggle") |> render_click()
    refute has_element?(view, row("YFB"))
  end

  test "the search box finds a code in a closed branch from its value alone", c do
    view = desk(c, :code)
    search(view, "YFB")

    assert has_element?(view, tree() <> "[data-searching]")
    # The match and its parents, all open; nothing else.
    assert has_element?(view, row("Y") <> ~s([aria-expanded="true"]))
    assert has_element?(view, row("YFB"))
    refute has_element?(view, row("FB"))
    # In a search the ▶ opens nothing: a click on it picks the row.
    refute has_element?(view, row("Y") <> ~s( .codelist-toggle[phx-click]))
    assert has_element?(view, tree() <> " .codelist-search button.btn", "Clear")

    search(view, "children's fic")
    assert has_element?(view, row("YFB"))

    search(view, "nothing like it")

    assert has_element?(
             view,
             tree() <> " p.codelist-empty",
             ~s(No matches for "nothing like it".)
           )

    view |> element(tree() <> " .codelist-search button.btn") |> render_click()
    refute has_element?(view, tree() <> "[data-searching]")
    assert has_element?(view, row("FB"))
  end

  test "with two trees in the form, a search in the first one searches the first tree", c do
    view = desk(c, :none)
    search(view, "YFB", "subject")

    assert has_element?(view, tree("subject") <> "[data-searching]")
    assert has_element?(view, row("YFB", "subject"))
    refute has_element?(view, tree("audience") <> "[data-searching]")

    search(view, "FBA", "audience")
    assert has_element?(view, row("FBA", "audience"))
    refute has_element?(view, row("YFB", "audience"))
    # The first tree keeps its own search.
    assert has_element?(view, row("YFB", "subject"))
    refute has_element?(view, row("FBA", "subject"))
  end

  test "a search over 200 matches shows the first 200, in the list's order, and says so", c do
    view = desk(c, :none)
    search(view, "F")

    codes =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(.codelist-tree-field[data-field-name="subject"] [role="treeitem"]))
      |> Enum.flat_map(&LazyHTML.attribute(&1, "data-code"))

    # The first 200 matches in the list's own order, depth first: Fiction's
    # 212 come before Children's fiction, which is not shown.
    assert length(codes) == 200
    assert Enum.take(codes, 3) == ["FB", "FBA", "FBZ1"]
    refute "YFB" in codes
    assert has_element?(view, tree() <> " p.codelist-empty", "The first 200 matches.")
  end

  test "pick, change, clear: the stored value is the code, then none", c do
    view = desk(c, :none)
    refute has_element?(view, tree() <> " .codelist-current")

    search(view, "YFB")
    pick(view, "YFB")
    assert content(c, :none)["subject"] == "YFB"
    assert has_element?(view, tree() <> " .codelist-current .mono", "YFB")
    assert has_element?(view, row("YFB") <> ~s([aria-selected="true"]))

    search(view, "FBA")
    pick(view, "FBA")
    assert content(c, :none)["subject"] == "FBA"

    EditorPost.press_on(view, element(view, tree() <> ~s( button[aria-label="Remove code"])))
    render(view)
    refute Map.has_key?(content(c, :none), "subject")
    refute has_element?(view, tree() <> " .codelist-current")
  end

  for {key, label} <- [code: "a code", int: "a number", obj: "an object"] do
    test "an edit to another field keeps the stored subject, #{label}, as it is stored", c do
      key = unquote(key)
      before = content(c, key)["subject"]
      view = desk(c, key)

      view
      |> form(@form, %{"doc" => %{"notes" => "typed"}})
      |> render_change(%{"_target" => ["doc", "notes"]})

      assert content(c, key)["notes"] == "typed"
      assert content(c, key)["subject"] === before
    end
  end

  test "a pick pressed in another document, or with no name, writes nothing", c do
    view = desk(c, :code)
    search(view, "YFB")
    other = Jason.encode!([@dataset, c.type, c.docs.none])

    view
    |> element(row("YFB"))
    |> render_click(%{"_bp_doc" => other, "_bp_doc_end" => other})

    render(view)
    assert content(c, :code)["subject"] == "FBA"
    assert content(c, :none)["subject"] == nil
    # Nothing was picked, so the tree still shows the stored code.
    assert has_element?(view, tree() <> " .codelist-current .mono", "FBA")
  end
end
