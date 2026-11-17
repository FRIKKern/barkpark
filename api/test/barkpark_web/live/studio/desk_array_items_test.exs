defmodule BarkparkWeb.Studio.DeskArrayItemsTest do
  @moduledoc """
  An object array's items on the desk, as the TanStack Studio draws them
  (`ArrayItemDialog`, `ArrayItemMenu`, `Handlers.ArrayItems`): a preview
  that opens the item's dialog, and an "…" menu with Remove, Copy,
  Duplicate, Add item before and Add item after. The old Studio keeps its
  open-in-place rows. The browser half (opening the dialog, the focus, the
  handle) is `bp-desk-array-menu.js`; the rig's specs drive it in Chrome.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  @links [
    %{
      "_key" => "l1",
      "kind" => "externalLink",
      "title" => "Sanity docs",
      "url" => "https://www.sanity.io/docs"
    },
    %{"_key" => "l2", "kind" => "docLink", "title" => "Related post", "target" => "aitems-target"}
  ]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "aitems_#{n}"

    links = %{
      "name" => "links",
      "title" => "Links",
      "type" => "arrayOf",
      "ordered" => true,
      "of" => %{
        "type" => "composite",
        "preview" => %{"title" => "title", "subtitle" => "target"},
        "options" => %{
          "typeField" => "kind",
          "fieldsByType" => %{
            "externalLink" => ["title", "url"],
            "docLink" => ["title", "target"]
          }
        },
        "fields" => [
          %{
            "name" => "kind",
            "title" => "Kind",
            "type" => "select",
            "options" => [
              %{"value" => "externalLink", "title" => "External link"},
              %{"value" => "docLink", "title" => "Document link"}
            ]
          },
          %{"name" => "title", "title" => "Title", "type" => "string"},
          %{"name" => "url", "title" => "URL", "type" => "url"},
          %{"name" => "target", "title" => "Target", "type" => "reference", "refType" => type}
        ]
      }
    }

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Items #{type}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"},
            links,
            %{
              "name" => "cards",
              "title" => "Cards",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [%{"name" => "label", "title" => "Label", "type" => "string"}]
              }
            }
          ]
        },
        @dataset
      )

    id = "aitems-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => "aitems-target", "title" => "The target post"},
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Items", "links" => @links},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-aitems-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-aitems", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     id: id,
     desk: "#{root}/_desk/#{type};#{id}",
     studio: "#{root}/#{type}/#{id}"}
  end

  defp desk(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, @form) end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp links(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    (doc.content || %{})["links"]
  end

  defp item(key), do: ~s(#{@form} li[data-item-path='links[_key=="#{key}"]'])

  defp menu_item(key, action),
    do: ~s(#{item(key)} [role="menu"] [data-desk-item-action="#{action}"])

  defp press(view, key, action),
    do: EditorPost.press_on(view, element(view, menu_item(key, action)))

  test "an item is its preview, an \"…\" menu named as Sanity's, and its fields in a dialog", c do
    view = desk(c)

    # The menu's button, by the id the TanStack Studio and Sanity give it.
    button = ~s(#{item("l1")} button[id='links[_key=="l1"]-menuButton'])

    assert has_element?(
             view,
             ~s(#{button}[aria-label="Item actions"][aria-haspopup="menu"][popovertarget='links[_key=="l1"]-menu'])
           )

    menu = ~s(#{item("l1")} [id='links[_key=="l1"]-menu'][popover][role="menu"])
    assert has_element?(view, ~s(#{menu}[aria-labelledby='links[_key=="l1"]-menuButton']))

    names =
      view
      |> element(menu)
      |> render()
      |> then(&Regex.scan(~r/role="menuitem"[^>]*>([^<]+)</, &1))
      |> Enum.map(fn [_, name] -> String.trim(name) end)

    assert names == ["Remove", "Copy", "Duplicate", "Add item before", "Add item after"]

    # The preview is a button that opens the dialog, named by the item's title.
    assert view |> element(~s(#{item("l1")} > button[data-desk-item-open])) |> render() =~
             "Sanity docs"

    dialog = ~s(#{item("l1")} > dialog[data-desk-item-dialog][aria-label="Links / Sanity docs"])
    assert has_element?(view, ~s(#{dialog} button[aria-label="Close dialog"]))
    assert has_element?(view, ~s(#{dialog} nav[aria-label="Breadcrumb"]))
    # The item's fields are in the dialog, under the names the form posts.
    assert has_element?(
             view,
             ~s(#{dialog} input[name="doc[links][0].title"][value="Sanity docs"])
           )

    assert has_element?(view, ~s(#{dialog} label[for]), "Title")

    # The handle, for the keyboard and the pointer.
    assert has_element?(
             view,
             ~s(#{item("l1")} > button[data-desk-item-handle][aria-roledescription="sortable"][aria-label="Move item 1"])
           )

    # No old row buttons on the desk's items.
    refute has_element?(view, ~s(#{item("l1")} .bp-array-btn-up))
  end

  test "the old Studio keeps its open-in-place rows", c do
    {:ok, view, _html} = live(c.conn, c.studio)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    refute has_element?(view, "[data-desk-item-dialog]")
    refute has_element?(view, "[data-desk-item-menu]")
    assert has_element?(view, "#editor-form details.bp-array-item")
  end

  test "Duplicate puts a copy after the item, under a new _key, and opens it", c do
    view = desk(c)
    press(view, "l1", "duplicate")

    assert [%{"_key" => "l1"}, copy, %{"_key" => "l2"}] = links(c)
    assert Map.delete(copy, "_key") == Map.delete(hd(@links), "_key")
    assert is_binary(copy["_key"]) and copy["_key"] not in ["l1", "l2"]
    assert_push_event(view, "desk:item-open", %{path: "doc[links]", index: 1})
    # The copy is drawn with its own dialog, by its own key.
    assert has_element?(
             view,
             ~s(#{item(copy["_key"])} > dialog[aria-label="Links / Sanity docs"])
           )
  end

  test "Add item before and after put an empty item there and open it", c do
    view = desk(c)
    press(view, "l2", "add-before")
    assert [%{"_key" => "l1"}, added, %{"_key" => "l2"}] = links(c)
    assert is_binary(added["_key"]) and added["title"] in [nil, ""]
    assert_push_event(view, "desk:item-open", %{path: "doc[links]", index: 1})

    press(view, "l2", "add-after")
    assert [_, _, %{"_key" => "l2"}, after_] = links(c)
    assert is_binary(after_["_key"])
    assert_push_event(view, "desk:item-open", %{path: "doc[links]", index: 3})
  end

  test "Remove takes the item out; the handle's drop moves one", c do
    view = desk(c)
    press(view, "l1", "remove")
    assert [%{"_key" => "l2"}] = links(c)

    press(view, "l2", "add-after")
    [_, %{"_key" => new}] = links(c)

    EditorPost.press(view, "array_op", %{
      "action" => "move_row",
      "field" => "links",
      "path" => "doc[links]",
      "index" => "1",
      "to" => "0"
    })

    assert [%{"_key" => ^new}, %{"_key" => "l2"}] = links(c)
  end

  test "the Add item button of an array of one item type opens the item it adds", c do
    view = desk(c)

    add =
      ~s(#{@form} fieldset[data-array-path="doc[cards]"] > button.bp-array-btn-add[phx-value-open="item"])

    EditorPost.press_on(view, element(view, add))
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    assert [%{"_key" => key}] = doc.content["cards"]
    assert_push_event(view, "desk:item-open", %{path: "doc[cards]", index: 0})
    assert has_element?(view, ~s(#{@form} li[data-item-path='cards[_key=="#{key}"]'] > dialog))
  end

  test "an add pressed in another document is not written", c do
    view = desk(c)
    control = element(view, menu_item("l1", "duplicate"))
    render_click(control, %{"_bp_doc" => Jason.encode!([@dataset, c.type, "someone-else"])})
    assert links(c) == @links
  end

  test "Copy answers with the item as a clipboard item that Paste field appends under a new key",
       c do
    view = desk(c)

    view
    |> element(menu_item("l1", "copy"))
    |> render_click(%{"field" => "links"})

    assert_push_event(view, "desk:field-copied", %{field: "links", json: json, text: text})
    assert text =~ "Sanity docs"

    assert %{
             "type" => "sanityClipboardItem",
             "valuePath" => ["links", %{"_key" => "l1"}],
             "barkpark" => %{
               "field" => %{
                 "append" => true,
                 "value" => [%{"_key" => "l1", "title" => "Sanity docs"}]
               }
             }
           } = Jason.decode!(json)

    paste = ~s([data-pane-editing] #editor-form #field-actions-menu button[data-desk-field-paste])

    view
    |> element(paste)
    |> render_click(EditorPost.named(view, %{"field" => "links", "clip" => json}))

    assert [%{"_key" => "l1"}, %{"_key" => "l2"}, pasted] = links(c)
    assert pasted["title"] == "Sanity docs" and pasted["_key"] not in ["l1", "l2"]
  end

  test "an edit of another field keeps every item as it was stored", c do
    view = desk(c)

    view
    |> form(@form, %{"doc" => %{"notes" => "typed"}})
    |> render_change(%{"_target" => ["doc", "notes"]})

    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    assert doc.content["notes"] == "typed"
    assert Jason.encode!(doc.content["links"]) == Jason.encode!(@links)
  end

  test "a doc link's preview names its target by its title", c do
    view = desk(c)

    assert view |> element(~s(#{item("l2")} > button[data-desk-item-open] .subtitle)) |> render() =~
             "The target post"

    refute has_element?(view, ~s(#{item("l1")} > button[data-desk-item-open] .subtitle))
  end

  test "an item's dialog shows its own type's fields, without the type select", c do
    view = desk(c)
    l1 = ~s(#{item("l1")} > dialog)
    l2 = ~s(#{item("l2")} > dialog)

    assert has_element?(view, ~s(#{l1} [name="doc[links][0].url"]))
    refute has_element?(view, ~s(#{l1} [name="doc[links][0].target"]))
    refute has_element?(view, ~s(#{l1} [name="doc[links][0].kind"]))
    refute has_element?(view, ~s(#{l2} [name="doc[links][1].url"]))
    refute has_element?(view, ~s(#{l2} [name="doc[links][1].kind"]))
  end

  test "an edit in an item's dialog keeps the item's type and its other fields", c do
    view = desk(c)

    view
    |> form(@form, %{"doc" => %{"links" => %{"0" => %{"title" => "Sanity docs v2"}}}})
    |> render_change(%{"_target" => ["doc", "links", "0", "title"]})

    assert [l1, l2] = links(c)
    assert l1 == Map.put(hd(@links), "title", "Sanity docs v2")
    assert l2 == List.last(@links)
  end

  test "Add item asks which type, and adds an item of that type that opens", c do
    view = desk(c)
    add = ~s(#{@form} fieldset[data-array-path="doc[links]"] .dk-add-item)
    assert has_element?(view, ~s(#{add} > button[aria-haspopup="menu"]), "Add item")

    names =
      view
      |> element(~s(#{add} [role="menu"]))
      |> render()
      |> then(&Regex.scan(~r/role="menuitem"[^>]*>([^<]+)</, &1))
      |> Enum.map(fn [_, name] -> String.trim(name) end)

    assert names == ["External link", "Document link"]

    EditorPost.press_on(
      view,
      element(view, ~s(#{add} [role="menuitem"][phx-value-kind="docLink"]))
    )

    assert [_, _, %{"kind" => "docLink", "_key" => key}] = links(c)
    assert_push_event(view, "desk:item-open", %{path: "doc[links]", index: 2})
    refute has_element?(view, ~s(#{item(key)} > dialog [name="doc[links][2].url"]))
  end
end
