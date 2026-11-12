defmodule BarkparkWeb.Studio.DeskDocMenuTest do
  @moduledoc """
  R21: the edit pane's "…" menu (`DocMenu`). Sanity's specs open a document's
  actions with a button named "Show document actions" (or by the substring
  "Document actions") and pick Publish, Unpublish, History, Duplicate or
  Delete from a menu. The desk had no such button, so 8 specs stopped there.
  Each item sends the Studio's own event; the Studio decides which exist.

  R24: Sanity's pane footer has the same actions behind "Open document
  actions" (`DocumentPane`); the specs click it by that exact name, or as the
  LAST "Document actions" button. The desk draws it below the editor. The
  old Studio has neither.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @button ~s([data-pane-editing] .pane-header button[aria-label="Show document actions"][aria-haspopup="menu"][popovertarget])
  @menu ~s([data-pane-editing] .pane-header [role="menu"][popover][id$="-editor-actions"])
  @footer ~s([data-pane-editing] .dk-edit-footer)
  @footer_button ~s(#{@footer} button[aria-label="Open document actions"][aria-haspopup="menu"][popovertarget])
  @footer_menu ~s(#{@footer} [role="menu"][popover])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "menu_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Menu #{type}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "menu-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Here"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-menu-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-menu", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, id: id}
  end

  defp open(c, type, id) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{type};#{id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp items(view, menu \\ @menu) do
    html = view |> element(menu) |> render()
    for [_, label] <- Regex.scan(~r/role="menuitem"[^>]*>\s*([^<]+?)\s*</, html), do: label
  end

  test "the edit pane's header has a menu button for the document's actions", c do
    view = open(c, c.type, c.id)

    assert has_element?(view, @button)

    menu_id =
      view |> element(@menu) |> render() |> then(&Regex.run(~r/id="([^"]+)"/, &1)) |> List.last()

    assert has_element?(view, ~s(#{@button}[popovertarget="#{menu_id}"]))
    assert has_element?(view, ~s(#{@menu}[aria-labelledby="#{menu_id}-button"]))

    labels = items(view)
    for label <- ["History", "Duplicate", "Delete"], do: assert(label in labels, inspect(labels))
    assert Enum.any?(labels, &(&1 in ["Publish", "Unpublish"])), inspect(labels)

    # The specs count the header's icon buttons by `.icon-btn` with a tip (J57).
    tipped = ~s([data-pane-editing] .pane-header .icon-btn[data-tip])
    assert has_element?(view, ~s(#{tipped}[aria-label="Show document actions"]))
    assert has_element?(view, ~s(#{tipped}.dk-close))
  end

  test "an item sends the Studio's own event: Duplicate makes a copy", c do
    view = open(c, c.type, c.id)
    count = fn -> length(Content.list_documents(c.type, @dataset, perspective: :drafts)) end
    before = count.()

    view |> element(~s(#{@menu} [data-desk-doc-action="duplicate-doc"])) |> render_click()

    assert eventually(fn -> count.() == before + 1 end), "no copy was made"
  end

  test "no menu over a document deleted elsewhere", c do
    view = open(c, c.type, c.id)
    {:ok, _} = Content.delete_document(c.id, c.type, @dataset)
    send(view.pid, {:document_changed, %{type: c.type, doc_id: c.id, mutation: "delete"}})

    assert eventually(fn -> has_element?(view, "[data-desk-edit-gone]") end)
    refute has_element?(view, @button)
    refute has_element?(view, @footer)
  end

  test "the edit pane's footer has an Open document actions button with the same items", c do
    view = open(c, c.type, c.id)

    assert has_element?(view, @footer_button)
    # Not a header icon button: J57 counts only those.
    refute has_element?(view, ~s(#{@footer_button}.icon-btn))

    menu_id =
      view
      |> element(@footer_menu)
      |> render()
      |> then(&Regex.run(~r/id="([^"]+)"/, &1))
      |> List.last()

    assert has_element?(view, ~s(#{@footer_button}[popovertarget="#{menu_id}"]))
    assert items(view, @footer_menu) == items(view)

    # The specs' `getByRole('button', {name: 'Document actions'}).last()` is this one.
    html = view |> element("[data-pane-editing]") |> render()
    names = for [_, n] <- Regex.scan(~r/aria-label="([^"]*[Dd]ocument actions)"/, html), do: n
    assert List.last(names) == "Open document actions", inspect(names)
  end

  test "the footer's Duplicate makes a copy too", c do
    view = open(c, c.type, c.id)
    count = fn -> length(Content.list_documents(c.type, @dataset, perspective: :drafts)) end
    before = count.()

    view |> element(~s(#{@footer_menu} [data-desk-doc-action="duplicate-doc"])) |> render_click()

    assert eventually(fn -> count.() == before + 1 end), "no copy was made"
  end

  # Control: the old Studio's editor draws neither button.
  test "the old Studio has no document actions menu", c do
    {:ok, _view, html} =
      live(c.conn, String.replace(c.base, "/_desk", "") <> "/#{c.type}/#{c.id}")

    assert html =~ ~s(id="editor-form"), "the old Studio's editor did not render"
    refute html =~ "Open document actions"
    refute html =~ "Show document actions"
    refute html =~ "dk-edit-footer"
  end
end
