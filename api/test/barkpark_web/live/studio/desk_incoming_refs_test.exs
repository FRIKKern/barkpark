defmodule BarkparkWeb.Studio.DeskIncomingRefsTest do
  @moduledoc """
  J17: Sanity's "Incoming references" on the desk's edit pane
  (`Desk.IncomingRefs`). The header's "Show document actions" menu has the
  item; it opens an inspector beside the form that lists every document
  referring to this one, grouped by type; a row opens the referring document
  in the next pane at the field that refers. The names are the ones
  barkpark-studio's `e2e/journeys/refs.spec.ts` (J17) finds them by.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @inspect_param "inspect=sanity%2Fstructure%2Fincoming-references"
  @header_menu ~s([data-pane-editing] .pane-header [role="menu"][id$="-editor-actions"])
  @footer_menu ~s([data-pane-editing] .doc-footer [role="menu"])
  @item ~s(#{@header_menu} button[role="menuitem"][data-desk-doc-action="incoming-references"])
  @panel ~s|[data-pane-editing] aside.inspector.incoming[aria-label="Incoming references"]:not([hidden])|

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "inc_author_#{n}"
    post = "inc_post_#{n}"
    note = "inc_note_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "Inc authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    for {type, title, field} <- [{post, "Inc posts", "author"}, {note, "Inc notes", "about"}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => title,
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => field, "title" => "Who", "type" => "reference", "to" => [author]}
            ]
          },
          @dataset
        )
    end

    ada = "inc-ada-#{n}"
    lone = "inc-lone-#{n}"

    for {id, title} <- [{ada, "Ada Referenced"}, {lone, "Lone Unreferenced"}] do
      {:ok, _} = Content.create_document(author, %{"doc_id" => id, "title" => title}, @dataset)
    end

    refer = fn type, id, title, field, to ->
      content = if to, do: %{field => %{"_ref" => to, "_type" => "reference"}}, else: %{}

      {:ok, _} =
        Content.upsert_document(
          type,
          %{"doc_id" => id, "title" => title, "content" => content},
          @dataset
        )
    end

    refer.(post, "inc-post-1-#{n}", "Post One", "author", ada)
    refer.(post, "inc-post-2-#{n}", "Post Two", "author", ada)
    refer.(post, "inc-post-3-#{n}", "Post Three", "author", nil)
    refer.(note, "inc-note-1-#{n}", "Note One", "about", ada)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-incoming-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-incoming", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     base: base,
     studio: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     author: author,
     post: post,
     note: note,
     ada: ada,
     lone: lone,
     n: n,
     refer: refer}
  end

  defp open(c, splat) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{splat}")
    render_async(view, 5_000)
    assert poll(view, fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp poll(view, fun, tries \\ 50) do
    render_async(view, 5_000)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  defp labels(view, menu) do
    html = view |> element(menu) |> render()
    for [_, label] <- Regex.scan(~r/role="menuitem"[^>]*>\s*([^<]+?)\s*</, html), do: label
  end

  defp row(id), do: ~s(#{@panel} a[href*="#{id}"])

  test "the header menu has Incoming references after History; the footer's has none", c do
    view = open(c, "#{c.author};#{c.ada}")

    header = labels(view, @header_menu)
    assert "Incoming references" in header

    assert Enum.find_index(header, &(&1 == "Incoming references")) ==
             Enum.find_index(header, &(&1 == "History")) + 1

    # A button, so the popover closes on the press (`popovertargetaction`).
    assert has_element?(view, ~s(#{@item}[popovertargetaction="hide"]), "Incoming references")
    refute "Incoming references" in labels(view, @footer_menu)
    # Closed: the holder is in the page, hidden and unnamed.
    assert has_element?(view, ~s([data-pane-editing] aside[data-desk-inspector][hidden]))
    refute has_element?(view, @panel)
  end

  test "the item opens the inspector in the URL: the referrers, grouped by type", c do
    view = open(c, "#{c.author};#{c.ada}")

    view |> element(@item) |> render_click()
    assert_patch(view, "#{c.base}/#{c.author};#{c.ada},#{@inspect_param}")

    assert has_element?(view, ~s(#{@panel} h2), "Incoming references")
    posts = ~s(#{@panel} section.incoming-group[aria-label="Inc posts"])
    notes = ~s(#{@panel} section.incoming-group[aria-label="Inc notes"])
    assert has_element?(view, ~s(#{posts} h3), "Inc posts")
    assert has_element?(view, ~s(#{posts} a[href*="inc-post-1-#{c.n}"]), "Post One")
    assert has_element?(view, ~s(#{posts} a[href*="inc-post-2-#{c.n}"]), "Post Two")
    assert has_element?(view, ~s(#{notes} a[href*="inc-note-1-#{c.n}"]), "Note One")
    # A post that refers to nobody is not listed, nor is the document itself.
    refute has_element?(view, row("inc-post-3-#{c.n}"))
    refute has_element?(view, ~s(#{@panel} li a), "Ada Referenced")

    assert view |> element(@panel) |> render() =~
             ~s(data-inspect="sanity/structure/incoming-references")
  end

  test "a row opens the referring document in the next pane, at the field that refers", c do
    view = open(c, "#{c.author};#{c.ada},#{@inspect_param}")
    assert has_element?(view, row("inc-post-1-#{c.n}"), "Post One")

    view |> element(row("inc-post-1-#{c.n}")) |> render_click()

    assert_patch(
      view,
      "#{c.base}/#{c.author};#{c.ada},#{@inspect_param};inc-post-1-#{c.n},type=#{c.post},path=author"
    )
  end

  test "a document nobody refers to says so; the close button takes the inspector out", c do
    view = open(c, "#{c.author};#{c.lone},#{@inspect_param}")

    assert has_element?(view, ~s(#{@panel} p.incoming-card), "No incoming references found.")
    refute has_element?(view, ~s(#{@panel} section.incoming-group))

    view
    |> element(~s(#{@panel} button[aria-label="Close incoming references"]))
    |> render_click()

    assert_patch(view, "#{c.base}/#{c.author};#{c.lone}")
    refute has_element?(view, @panel)
    assert has_element?(view, ~s([data-pane-editing] aside[data-desk-inspector][hidden]))
  end

  test "someone else's save: a document that starts to refer comes, one that stops goes", c do
    view = open(c, "#{c.author};#{c.ada},#{@inspect_param}")
    assert has_element?(view, row("inc-post-2-#{c.n}"))
    refute has_element?(view, row("inc-post-3-#{c.n}"))

    c.refer.(c.post, "inc-post-3-#{c.n}", "Post Three", "author", c.ada)
    c.refer.(c.post, "inc-post-2-#{c.n}", "Post Two", "author", c.lone)
    send(view.pid, {:document_changed, %{type: c.post, doc_id: "inc-post-3-#{c.n}"}})

    assert poll(view, fn -> has_element?(view, row("inc-post-3-#{c.n}"), "Post Three") end)
    refute has_element?(view, row("inc-post-2-#{c.n}"))
    assert has_element?(view, row("inc-post-1-#{c.n}"))
  end

  test "another inspector's name in the URL does not open this one", c do
    view = open(c, "#{c.author};#{c.ada},inspect=sanity%2Fcomments")

    refute has_element?(view, @panel)
    assert has_element?(view, ~s([data-pane-editing] aside[data-inspect="comments"][hidden]))
    # The desk does not draw that one, and says so.
    assert has_element?(view, "[data-pane-editing] [data-desk-left-out]")

    # Validation is drawn (`ValidationPanel`): not this panel, and no note.
    view = open(c, "#{c.author};#{c.ada},inspect=sanity%2Fstructure%2Fvalidation")
    refute has_element?(view, @panel)
    assert has_element?(view, ~s([data-pane-editing] aside[aria-label="Validation"]))
    refute has_element?(view, "[data-pane-editing] [data-desk-left-out]")
  end

  test "the open inspector is not said to be left out; a revision beside it still is", c do
    view = open(c, "#{c.author};#{c.ada},#{@inspect_param}")
    assert has_element?(view, @panel)
    refute has_element?(view, "[data-pane-editing] [data-desk-left-out]")

    view = open(c, "#{c.author};#{c.ada},#{@inspect_param},rev=abc123")
    assert has_element?(view, @panel)
    assert has_element?(view, "[data-pane-editing] [data-desk-left-out]", "abc123")
    refute has_element?(view, "[data-pane-editing] [data-desk-left-out]", "inspectors")
  end

  test "opening focuses the close button; Escape inside closes it and hands the focus back", c do
    view = open(c, "#{c.author};#{c.ada},#{@inspect_param}")

    close = view |> element(~s(#{@panel} button[data-desk-inspector-close])) |> render()
    # `phx-mounted`: the button takes the focus when the panel is drawn.
    assert close =~ ~r/phx-mounted="[^"]*focus/

    # Escape patches the param out, then focuses the "…" button. LiveView runs
    # a `phx-keydown` only on the element the key was pressed on, so the
    # binding is on each focusable element of the panel, not on the panel.
    assert close =~ ~s(phx-key="escape")
    assert close =~ ~r/phx-keydown="[^"]*patch[^"]*focus[^"]*-editor-actions-button/
    holder = view |> element(@panel) |> render() |> String.split(">", parts: 2) |> hd()
    refute holder =~ "phx-keydown"

    view
    |> element(~s(#{@panel} button[data-desk-inspector-close]))
    |> render_keydown(%{"key" => "Escape"})

    assert_patch(view, "#{c.base}/#{c.author};#{c.ada}")
    refute has_element?(view, @panel)
  end

  test "Escape on a row closes the panel too", c do
    view = open(c, "#{c.author};#{c.ada},#{@inspect_param}")
    link = row("inc-post-1-#{c.n}")
    assert view |> element(link) |> render() =~ ~s(phx-key="escape")

    view |> element(link) |> render_keydown(%{"key" => "Escape"})
    assert_patch(view, "#{c.base}/#{c.author};#{c.ada}")
    refute has_element?(view, @panel)
  end

  test "a re-read while the database is out keeps the list and the page", c do
    view = open(c, "#{c.author};#{c.ada},#{@inspect_param}")
    assert has_element?(view, row("inc-post-1-#{c.n}"))

    Barkpark.Repo.query!("ALTER TABLE documents RENAME TO documents_out")
    send(view.pid, :desk_refresh)
    # A message the page does not know does not stop it either.
    send(view.pid, {:desk_refresh, :weird})
    html = render(view)
    Barkpark.Repo.query!("ALTER TABLE documents_out RENAME TO documents")

    assert Process.alive?(view.pid)
    assert html =~ "inc-post-1-#{c.n}"
    assert has_element?(view, row("inc-post-1-#{c.n}"), "Post One")
    assert has_element?(view, row("inc-note-1-#{c.n}"))
  end

  test "more than 100 referrers: the first 100 and a line that says how many there are", c do
    for i <- 1..101 do
      c.refer.(c.post, "inc-many-#{i}-#{c.n}", "Many #{i}", "author", c.lone)
    end

    view = open(c, "#{c.author};#{c.lone},#{@inspect_param}")

    rows =
      view |> element(@panel) |> render() |> String.split("data-desk-incoming-row=") |> length()

    assert rows - 1 == 100

    assert has_element?(
             view,
             ~s(#{@panel} [role="status"][data-desk-incoming-more]),
             "Showing the first 100 of 101."
           )

    # At the cap or under it there is no such line.
    view = open(c, "#{c.author};#{c.ada},#{@inspect_param}")
    refute has_element?(view, ~s(#{@panel} [data-desk-incoming-more]))
  end

  # Control: the old Studio's document actions are as they were.
  test "the old Studio has no Incoming references", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/open/#{c.author}/#{c.ada}")
    render_async(view, 5_000)
    assert poll(view, fn -> has_element?(view, "#editor-form") end)

    refute render(view) =~ "Incoming references"
    refute has_element?(view, "aside[data-desk-inspector]")
  end
end
