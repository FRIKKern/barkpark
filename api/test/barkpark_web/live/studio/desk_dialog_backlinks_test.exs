defmodule BarkparkWeb.Studio.DeskDialogBacklinksTest do
  @moduledoc """
  J17 and B07: the desk's delete and unpublish dialogs list who refers to the
  open document from the same read as the Incoming references panel
  (`IncomingRefs.referrers/3`, `Content.Graph.backlinks/2`). So a referrer
  that exists only as a draft is listed (barkpark-studio
  `e2e/journeys/refs.spec.ts:398`: the dialog's count is the backlinks
  index's), and the count in `role="status"` is the number of rows
  (`unpublish-guard.spec.ts:22-23`), also when a document refers from two
  fields. What a confirm deletes, unpublishes or disconnects is the Studio
  handler's, unchanged.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "[data-pane-editing]"
  @delete ~s(#{@pane} [role="dialog"][aria-modal="true"][data-desk-dialog="delete"])
  @unpublish ~s(#{@pane} [role="dialog"][aria-modal="true"][data-desk-dialog="unpublish"])
  @panel ~s|#{@pane} aside.inspector.incoming[aria-label="Incoming references"]:not([hidden])|
  @inspect "inspect=sanity%2Fstructure%2Fincoming-references"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "dbl_author_#{n}"
    post = "dbl_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "Dbl authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "Dbl posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]},
            %{"name" => "editor", "title" => "Editor", "type" => "reference", "to" => [author]}
          ]
        },
        @dataset
      )

    ada = "dbl-ada-#{n}"
    solo = "dbl-solo-#{n}"
    other = "dbl-other-#{n}"

    for {id, title} <- [{ada, "Ada Referenced"}, {solo, "Solo Drafted"}, {other, "Other Author"}] do
      {:ok, _} = Content.create_document(author, %{"doc_id" => id, "title" => title}, @dataset)
      {:ok, _} = Content.publish_document(id, author, @dataset)
    end

    ref = fn id -> %{"_ref" => id, "_type" => "reference"} end

    # Post One refers to Ada from two fields, Post Two from one; both are
    # published and in the edge index.
    for {id, title, content} <- [
          {"dbl-post-1-#{n}", "Post One", %{"author" => ref.(ada), "editor" => ref.(ada)}},
          {"dbl-post-2-#{n}", "Post Two", %{"author" => ref.(ada)}}
        ] do
      {:ok, _} =
        Content.create_document(
          post,
          %{"doc_id" => id, "title" => title, "content" => content},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, post, @dataset)

      # The handlers read `content_edges`, which a test write does not derive.
      for field <- Map.keys(content) do
        {:ok, _} = Content.add_edge(id, ada, field, dataset: @dataset, plugin_source: nil)
      end
    end

    # Never published, so the edge index has no row for either.
    for {id, title, to} <- [
          {"dbl-draft-3-#{n}", "Draft Three", ada},
          {"dbl-draft-4-#{n}", "Draft Four", solo}
        ] do
      {:ok, _} =
        Content.create_document(
          post,
          %{"doc_id" => id, "title" => title, "content" => %{"author" => ref.(to)}},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-dialog-backlinks-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id

    {:ok, _} =
      Auth.create_token(raw, "desk-dialog-backlinks", @dataset, ~w(read write admin), ws_id)

    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     base: base,
     studio: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     author: author,
     post: post,
     ada: ada,
     solo: solo,
     other: other,
     n: n}
  end

  defp open(c, splat) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.author};#{splat}")
    render_async(view, 5_000)
    assert poll(view, fn -> has_element?(view, "#{@pane} #editor-form") end)
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

  # The titles of the dialog's rows, in order.
  defp titles(view, dialog) do
    html = view |> element("#{dialog} ul.used-in") |> render()
    for [_, title] <- Regex.scan(~r/class="t">\s*([^<]+?)\s*</, html), do: title
  end

  defp exists?(c, id), do: match?({:ok, _}, Content.get_document(id, c.author, @dataset))

  defp published?(c, id) do
    {_doc, _draft?, published?} = Content.fetch_doc_with_draft(c.author, id, @dataset)
    published?
  end

  # What a post holds in its author field, draft or published.
  defp author_of(c, id) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.post, id, @dataset)
    (doc.content || %{})["author"]
  end

  test "Delete lists a referrer that exists only as a draft, and counts it", c do
    view = open(c, c.ada)
    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})

    assert has_element?(
             view,
             ~s(#{@delete} [role="status"]),
             "3 documents refer to “Ada Referenced”"
           )

    assert Enum.sort(titles(view, @delete)) == ["Draft Three", "Post One", "Post Two"]

    assert has_element?(
             view,
             ~s(#{@delete} ul.used-in li a[target="_blank"][href$="#{c.post};dbl-draft-3-#{c.n}"]),
             "Draft Three"
           )
  end

  test "a document only a draft refers to: the dialog says so and offers the disconnect", c do
    view = open(c, c.solo)
    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})

    assert has_element?(
             view,
             ~s(#{@delete} [role="status"]),
             "1 document refers to “Solo Drafted”"
           )

    assert titles(view, @delete) == ["Draft Four"]

    assert has_element?(
             view,
             ~s(#{@delete} button.danger[phx-click="confirm-delete"][phx-value-disconnect="true"]),
             "Disconnect references and delete"
           )

    refute has_element?(view, ~s(#{@delete} button), "Delete document")

    # Opening it wrote nothing; Cancel leaves both documents as they were.
    view |> element(~s(#{@delete} button[data-modal-focus])) |> render_click()
    assert exists?(c, c.solo)
    assert author_of(c, "dbl-draft-4-#{c.n}")["_ref"] == c.solo

    # The press takes the reference out of the draft, then deletes.
    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})

    BarkparkWeb.EditorPost.press_on(
      view,
      element(view, ~s(#{@delete} button[phx-value-disconnect="true"]))
    )

    refute exists?(c, c.solo)
    assert author_of(c, "dbl-draft-4-#{c.n}") == nil
  end

  test "Unpublish: one row per referring document, so the count is the number of rows", c do
    view = open(c, c.ada)
    BarkparkWeb.EditorPost.press(view, "unpublish", %{})

    assert has_element?(
             view,
             ~s(#{@unpublish} [role="status"]),
             "3 documents refer to “Ada Referenced”"
           )

    # Post One refers from two fields and is one row.
    assert Enum.sort(titles(view, @unpublish)) == ["Draft Three", "Post One", "Post Two"]

    html = view |> element("#{@unpublish} ul.used-in") |> render()
    assert length(Regex.scan(~r/<li/, html)) == 3
    assert length(Regex.scan(~r/class="s">\s*Dbl posts \/ (author|editor)\s*</, html)) == 3
    assert published?(c, c.ada)
  end

  test "the dialogs and the Incoming references panel name the same documents", c do
    view = open(c, "#{c.ada},#{@inspect}")

    panel = view |> element(@panel) |> render()
    in_panel = for [_, id] <- Regex.scan(~r/data-desk-incoming-row="([^"]+)"/, panel), do: id
    assert length(in_panel) == 3

    for {event, dialog} <- [{"delete-doc", @delete}, {"unpublish", @unpublish}] do
      BarkparkWeb.EditorPost.press(view, event, %{})
      html = view |> element("#{dialog} ul.used-in") |> render()
      in_dialog = for [_, id] <- Regex.scan(~r/href="[^"]*;([^";]+)"/, html), do: id
      assert Enum.sort(in_dialog) == Enum.sort(in_panel), event
      view |> element(~s(#{dialog} button[data-modal-focus])) |> render_click()
      refute has_element?(view, dialog)
    end
  end

  test "a referrer that comes while the dialog is closed is in the next one", c do
    view = open(c, c.other)
    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})
    refute has_element?(view, ~s(#{@delete} ul.used-in))
    assert has_element?(view, ~s(#{@delete} button.danger), "Delete document")
    view |> element(~s(#{@delete} button[data-modal-focus])) |> render_click()

    {:ok, _} =
      Content.create_document(
        c.post,
        %{
          "doc_id" => "dbl-late-#{c.n}",
          "title" => "Late Draft",
          "content" => %{"author" => %{"_ref" => c.other, "_type" => "reference"}}
        },
        @dataset
      )

    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})
    assert titles(view, @delete) == ["Late Draft"]
  end

  # The deleted document's pane goes and the focus with it; the Studio says
  # which document went, and the desk's script puts the focus on a row of the
  # list that is left (`bp-desk.js`, `_focusAfterDelete`).
  test "after a delete the page is told which document went, and the desk's script listens", c do
    view = open(c, c.other)
    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})

    BarkparkWeb.EditorPost.press_on(
      view,
      element(view, ~s(#{@delete} button.danger), "Delete document")
    )

    other = c.other
    assert_push_event(view, "bp:focus-after-delete", %{id: ^other})
    refute exists?(c, c.other)

    script = File.read!(Application.app_dir(:barkpark, "priv/static/assets/bp-desk.js"))

    assert script =~
             ~s|window.addEventListener("phx:bp:focus-after-delete", hook._focusAfterDelete)|

    assert script =~
             ~s|window.removeEventListener("phx:bp:focus-after-delete", this._focusAfterDelete)|
  end

  # The handler is main's: a hand-sent confirm disconnects only for the exact
  # string "true", and only the open document goes.
  test "a hand-sent confirm-delete with another id and disconnect not \"true\" disconnects nothing",
       c do
    view = open(c, c.solo)

    BarkparkWeb.EditorPost.press(view, "confirm-delete", %{
      "disconnect" => "TRUE",
      "id" => c.ada,
      "type" => c.post
    })

    refute exists?(c, c.solo)
    assert exists?(c, c.ada)
    assert author_of(c, "dbl-draft-4-#{c.n}")["_ref"] == c.solo
    assert author_of(c, "dbl-post-2-#{c.n}")["_ref"] == c.ada
  end

  # Control: the old Studio's modal reads the handler's list, as it did.
  test "the old Studio's delete modal is as it was", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/open/#{c.author}/#{c.ada}")
    render_async(view, 5_000)
    assert poll(view, fn -> has_element?(view, "#editor-form") end)

    BarkparkWeb.EditorPost.press(view, "delete-doc", %{})

    assert has_element?(view, "#delete-modal-dialog")
    refute has_element?(view, "[data-desk-dialog]")
    refute has_element?(view, "ul.used-in")
    refute render(view) =~ "Draft Three"
  end
end
