defmodule BarkparkWeb.Studio.DeskShareTest do
  @moduledoc """
  J28: Sanity's "Share document" header button opens a menu with "Copy
  document ID" and "Copy document URL". The copy and its toast are the
  browser's (`bp-desk.js`); here: the button, the menu, and that each item
  carries the right text: the published id, and a path that opens this
  document alone, also from a split.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @button ~s([data-pane-editing] > .pane-header button.icon-btn[aria-label="Share document"][data-tip][aria-haspopup="menu"])
  @copy_id ~s([data-pane-editing] [role="menu"] [role="menuitem"][data-desk-copied="Document ID copied to clipboard"])
  @copy_url ~s([data-pane-editing] [role="menu"] [role="menuitem"][data-desk-copied="Document URL copied to clipboard"])
  @split ~s([data-pane-editing] .pane-header a.icon-btn[aria-label="Split pane right"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "share_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Share #{type}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    id = "share-#{n}"
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Shared"}, @dataset)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-share-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-share", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok, conn: conn, base: base, type: type, id: id}
  end

  defp open(c, path) do
    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp copied(view, selector) do
    [_, value] = Regex.run(~r/data-desk-copy="([^"]*)"/, view |> element(selector) |> render())
    value
  end

  test "the edit pane's header has Share document, with its two copy items", c do
    view = open(c, "#{c.base}/#{c.type};#{c.id}")

    assert has_element?(view, @button)
    assert has_element?(view, @copy_id, "Copy document ID")
    assert has_element?(view, @copy_url, "Copy document URL")
    # One toast, a popover over everything, read out when it is filled.
    assert has_element?(
             view,
             ~s([data-pane-editing] .dk-toast[popover="manual"][role="status"][aria-live="polite"])
           )
  end

  test "Copy document ID carries the document's id", c do
    view = open(c, "#{c.base}/#{c.type};#{c.id}")
    assert copied(view, @copy_id) == c.id
  end

  test "Copy document URL carries a path that opens the same document", c do
    view = open(c, "#{c.base}/#{c.type};#{c.id}")
    path = copied(view, @copy_url)
    assert path == "#{c.base}/#{c.type};#{c.id}"

    again = open(c, path)

    assert has_element?(
             again,
             ~s([data-pane-editing] #editor-form input[name="doc[title]"][value="Shared"])
           )
  end

  test "from a split, the URL names the document once", c do
    view = open(c, "#{c.base}/#{c.type};#{c.id}")
    view |> element(@split) |> render_click()
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] [data-desk-close-split]") end)

    assert copied(view, @copy_url) == "#{c.base}/#{c.type};#{c.id}"
  end
end
