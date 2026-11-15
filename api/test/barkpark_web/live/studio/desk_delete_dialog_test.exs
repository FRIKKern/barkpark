defmodule BarkparkWeb.Studio.DeskDeleteDialogTest do
  @moduledoc """
  J17: the desk's own delete dialog (`Desk.DeleteDialog`), with the names
  barkpark-studio's `e2e/journeys/refs.spec.ts` finds it by: a dialog titled
  "Delete document?", "N documents refer to “title”" in a `role="status"`,
  and the referring documents in `ul.used-in`. The Studio's delete handler
  still does the work; the old Studio keeps its own modal.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @dialog ~s([data-pane-editing] [role="dialog"][aria-modal="true"][data-desk-dialog="delete"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "del_author_#{n}"
    post = "del_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "Del authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "Del posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]},
            %{"name" => "editor", "title" => "Editor", "type" => "reference", "to" => [author]}
          ]
        },
        @dataset
      )

    ada = "del-ada-#{n}"
    lone = "del-lone-#{n}"

    for {id, title} <- [{ada, "Ada Referenced"}, {lone, "Lone Unreferenced"}] do
      {:ok, _} = Content.create_document(author, %{"doc_id" => id, "title" => title}, @dataset)
      {:ok, _} = Content.publish_document(id, author, @dataset)
    end

    ref = %{"_ref" => ada, "_type" => "reference"}

    # Post One refers twice (two fields), Post Two once: two documents.
    for {id, title, content} <- [
          {"del-post-1-#{n}", "Post One", %{"author" => ref, "editor" => ref}},
          {"del-post-2-#{n}", "Post Two", %{"author" => ref}}
        ] do
      {:ok, _} =
        Content.create_document(
          post,
          %{"doc_id" => id, "title" => title, "content" => content},
          @dataset
        )

      {:ok, _} = Content.publish_document(id, post, @dataset)

      # The guard reads `content_edges`, which a test write does not derive.
      for field <- Map.keys(content) do
        {:ok, _} = Content.add_edge(id, ada, field, dataset: @dataset, plugin_source: nil)
      end
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-delete-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-delete", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     base: base,
     studio: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     author: author,
     post: post,
     ada: ada,
     lone: lone,
     n: n}
  end

  defp open(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.base}/#{c.author};#{id}")
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

  defp exists?(c, id), do: match?({:ok, _}, Content.get_document(id, c.author, @dataset))

  test "Delete on a referenced document: how many refer, and which, in ul.used-in", c do
    view = open(c, c.ada)
    render_hook(view, "delete-doc", %{})

    assert has_element?(view, ~s(#{@dialog}[phx-hook="ModalFocus"]))
    assert has_element?(view, ~s(#{@dialog} h2), "Delete document?")

    title_id =
      view
      |> element(~s(#{@dialog} h2))
      |> render()
      |> then(&Regex.run(~r/id="([^"]+)"/, &1))
      |> List.last()

    assert has_element?(view, ~s(#{@dialog}[aria-labelledby="#{title_id}"]))
    assert has_element?(view, @dialog, "Are you sure you want to delete this document?")

    # Two documents, though one of them refers from two fields.
    used = ~s(#{@dialog} section[aria-label="Used in"])

    assert has_element?(
             view,
             ~s(#{used} [role="status"]),
             "2 documents refer to “Ada Referenced”"
           )

    assert has_element?(
             view,
             used,
             "You may not be able to delete “Ada Referenced” because the following documents refer to it:"
           )

    assert has_element?(
             view,
             used,
             "If you delete this document, documents that refer to it will no longer be able to access it."
           )

    rows = view |> element(~s(#{used} ul.used-in)) |> render() |> then(&Regex.scan(~r/<li/, &1))
    assert length(rows) == 2

    one = ~s(#{used} ul.used-in li a[target="_blank"][href$="#{c.post};del-post-1-#{c.n}"])
    assert has_element?(view, one, "Post One")

    assert has_element?(
             view,
             ~s|#{used} ul.used-in li a[title="Open in a new tab (Del posts)"]|,
             "Post Two"
           )

    # The focus starts on Cancel; the red button says what it will do.
    assert has_element?(
             view,
             ~s(#{@dialog} button[data-modal-focus][phx-click="close-delete"]),
             "Cancel"
           )

    assert has_element?(
             view,
             ~s(#{@dialog} button.danger[phx-click="confirm-delete"][phx-value-disconnect="true"]),
             "Disconnect references and delete"
           )

    refute has_element?(view, ~s(#{@dialog} button), "Delete document")
    # The Studio's own modal is not drawn on the desk.
    refute has_element?(view, "#delete-modal-dialog")
    refute has_element?(view, ".delete-modal")
  end

  test "Cancel, Escape and the close button close it and delete nothing", c do
    view = open(c, c.ada)

    for close <- [
          fn -> view |> element(~s(#{@dialog} button[data-modal-focus])) |> render_click() end,
          fn -> view |> element(~s(#{@dialog} button[aria-label="Close"])) |> render_click() end,
          fn -> view |> element(@dialog) |> render_keydown(%{"key" => "Escape"}) end
        ] do
      render_hook(view, "delete-doc", %{})
      assert has_element?(view, @dialog)
      close.()
      refute has_element?(view, @dialog)
    end

    assert exists?(c, c.ada)
  end

  test "a document nobody refers to: no list, and Delete document deletes it", c do
    view = open(c, c.lone)
    render_hook(view, "delete-doc", %{})

    assert has_element?(view, ~s(#{@dialog} .delete-preview), "Lone Unreferenced")
    refute has_element?(view, ~s(#{@dialog} [role="status"]))
    refute has_element?(view, ~s(#{@dialog} ul.used-in))
    refute has_element?(view, ~s(#{@dialog} button), "Disconnect references and delete")

    view
    |> element(
      ~s|#{@dialog} button.danger[phx-click="confirm-delete"]:not([phx-value-disconnect])|,
      "Delete document"
    )
    |> render_click()

    assert_patch(view, "#{c.base}/#{c.author}")
    refute has_element?(view, @dialog)
    refute exists?(c, c.lone)
  end

  # Control: the handler is shared, and the old Studio's modal is as it was.
  test "the old Studio keeps its own delete modal and words", c do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/open/#{c.author}/#{c.ada}")
    render_async(view, 5_000)
    assert poll(view, fn -> has_element?(view, "#editor-form") end)

    render_hook(view, "delete-doc", %{})

    assert has_element?(
             view,
             "#delete-modal-dialog.delete-modal[role=dialog] #delete-modal-title",
             "Delete document"
           )

    assert has_element?(
             view,
             "#delete-modal-dialog .delete-ref-item .delete-ref-title",
             "Post One"
           )

    assert has_element?(view, "#delete-modal-dialog .delete-ref-meta", "#{c.post} / author")

    assert has_element?(
             view,
             ~s(#delete-modal-dialog button.btn-destructive[phx-value-disconnect="true"]),
             "Disconnect references and delete"
           )

    refute has_element?(view, "[data-desk-dialog]")
    refute has_element?(view, "ul.used-in")
  end
end
