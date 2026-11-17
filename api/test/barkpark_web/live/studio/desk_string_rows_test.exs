defmodule BarkparkWeb.Studio.DeskStringRowsTest do
  @moduledoc """
  An array of strings on the desk, as the TanStack Studio draws it
  (`ArrayStringRow`, string-arrays J34): each row is a drag handle, the
  value's input and an "…" menu with Remove, Copy, Duplicate, Add item
  before and Add item after. The old Studio keeps its row buttons. The
  writes are the object item's `array_op` presses, and the stored list
  stays a list of plain strings. The browser half (the handle's keyboard
  and pointer moves, the focus) is `bp-desk-array-menu.js` and
  `bp-array-focus.js`; the rig's specs drive it in Chrome.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @form "[data-pane-editing] #editor-form"
  @hl ["Point one", "Point two", "Point three"]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "srows_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Rows #{type}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"},
            %{
              "name" => "highlights",
              "title" => "Highlights",
              "type" => "arrayOf",
              "ordered" => true,
              "of" => %{"type" => "string"}
            }
          ]
        },
        @dataset
      )

    id = "srows-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Rows", "highlights" => @hl},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-srows-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-srows", @dataset, ~w(read write admin), ws_id)
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

  # The stored list, as the draft holds it.
  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    (doc.content || %{})["highlights"]
  end

  defp row(i), do: ~s(#{@form} ol[id="highlights"] > li[data-item-path="highlights[#{i}]"])

  defp menu_item(i, action),
    do: ~s(#{row(i)} [role="menu"] [data-desk-item-action="#{action}"])

  defp press(view, i, action),
    do: EditorPost.press_on(view, element(view, menu_item(i, action)))

  test "a string row is a handle, its input and an \"…\" menu named as Sanity's", c do
    view = desk(c)

    assert has_element?(
             view,
             ~s(#{row(0)} > button[data-desk-item-handle][aria-roledescription="sortable"][aria-label="Move item 1"])
           )

    assert has_element?(view, ~s(#{row(1)} input[id="highlights[1]"][value="Point two"]))

    # The menu's button, by the id the TanStack Studio and Sanity give it.
    assert has_element?(
             view,
             ~s(#{row(1)} button[id="highlights[1]-menuButton"][aria-label="Item actions"][popovertarget="highlights[1]-menu"])
           )

    names =
      view
      |> element(~s(#{row(1)} [id="highlights[1]-menu"][role="menu"]))
      |> render()
      |> then(&Regex.scan(~r/role="menuitem"[^>]*>([^<]+)</, &1))
      |> Enum.map(fn [_, name] -> String.trim(name) end)

    assert names == ["Remove", "Copy", "Duplicate", "Add item before", "Add item after"]

    # The handles' keyboard help, and the array's path for the handle's drop.
    assert has_element?(view, ~s(#{@form} ol[id="highlights"][aria-describedby]))
    assert has_element?(view, ~s(#{@form} fieldset[data-array-path="doc[highlights]"]))
    # No old row buttons, and no item dialog: a string is edited in its row.
    refute has_element?(view, ~s(#{row(0)} .bp-array-btn-up))
    refute has_element?(view, ~s(#{row(0)} .bp-array-btn-remove))
    refute has_element?(view, ~s(#{row(0)} dialog))
  end

  test "the old Studio keeps its row buttons", c do
    {:ok, view, _html} = live(c.conn, c.studio)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    assert has_element?(view, ~s(#editor-form .bp-array-btn-remove[phx-value-field="highlights"]))
    refute has_element?(view, "#editor-form [data-desk-item-handle]")
    refute has_element?(view, "#editor-form [data-desk-item-menu]")
  end

  test "Remove from the menu takes the row out; the list stays plain strings", c do
    view = desk(c)
    press(view, 1, "remove")
    assert stored(c) == ["Point one", "Point three"]
    refute has_element?(view, ~s(#{@form} [id="highlights[2]"]))
  end

  test "the handle's drop moves a row; the list stays plain strings", c do
    view = desk(c)
    handle = ~s(#{row(0)} > button[data-desk-item-handle])

    assert has_element?(
             view,
             ~s(#{handle}[data-move-event="array_op"][data-move-field="highlights"][data-move-path="doc[highlights]"][data-move-index="0"])
           )

    # What bp-desk-array-menu.js presses on the drop.
    EditorPost.press(view, "array_op", %{
      "action" => "move_row",
      "field" => "highlights",
      "path" => "doc[highlights]",
      "index" => "0",
      "to" => "1"
    })

    assert stored(c) == ["Point two", "Point one", "Point three"]
    assert has_element?(view, ~s(#{@form} input[id="highlights[0]"][value="Point two"]))
  end

  test "Duplicate puts the same string after it and opens nothing", c do
    view = desk(c)
    press(view, 0, "duplicate")
    assert stored(c) == ["Point one", "Point one", "Point two", "Point three"]
    refute_push_event(view, "desk:item-open", _)
  end

  test "Add item before and after put an empty string there, and its input takes the caret",
       c do
    view = desk(c)
    press(view, 1, "add-before")
    assert stored(c) == ["Point one", "", "Point two", "Point three"]
    assert_push_event(view, "desk:item-open", %{path: "doc[highlights]", index: 1})

    press(view, 3, "add-after")
    assert stored(c) == ["Point one", "", "Point two", "Point three", ""]
    assert_push_event(view, "desk:item-open", %{path: "doc[highlights]", index: 4})
  end

  test "an edit of another field after a move keeps the list as plain strings", c do
    view = desk(c)

    EditorPost.press(view, "array_op", %{
      "action" => "move_row",
      "field" => "highlights",
      "path" => "doc[highlights]",
      "index" => "2",
      "to" => "0"
    })

    view
    |> form(@form, %{"doc" => %{"notes" => "typed"}})
    |> render_change(%{"_target" => ["doc", "notes"]})

    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    assert doc.content["notes"] == "typed"

    assert Jason.encode!(doc.content["highlights"]) ==
             Jason.encode!(["Point three", "Point one", "Point two"])
  end

  test "a menu press made in another document is not written", c do
    view = desk(c)
    control = element(view, menu_item(0, "remove"))
    render_click(control, %{"_bp_doc" => Jason.encode!([@dataset, c.type, "someone-else"])})
    assert stored(c) == @hl
  end

  test "Copy answers with the string as a clipboard item", c do
    view = desk(c)

    view
    |> element(menu_item(2, "copy"))
    |> render_click(%{"field" => "highlights"})

    assert_push_event(view, "desk:field-copied", %{field: "highlights", json: json})

    assert %{
             "type" => "sanityClipboardItem",
             "valuePath" => ["highlights", 2],
             "value" => ["Point three"],
             "patchType" => "append"
           } = Jason.decode!(json)
  end
end
