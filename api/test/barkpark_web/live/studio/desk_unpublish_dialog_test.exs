defmodule BarkparkWeb.Studio.DeskUnpublishDialogTest do
  @moduledoc """
  B07 and J04: the desk's own unpublish dialog (`Desk.UnpublishDialog`), with
  the names barkpark-studio's `e2e/journeys/unpublish-guard.spec.ts` and
  `lifecycle.spec.ts:123` find it by. On the desk Unpublish always asks; the
  count of referring documents is in a `role="status"`; "Disconnect
  references and unpublish" rewrites the referring documents only when it is
  pressed. The old Studio keeps its modal, and still unpublishes a document
  nobody refers to without asking.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @dialog ~s([data-pane-editing] [role="dialog"][aria-modal="true"][data-desk-dialog="unpublish"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "unp_author_#{n}"
    post = "unp_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "Unp authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "Unp posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]}
          ]
        },
        @dataset
      )

    ada = "unp-ada-#{n}"
    lone = "unp-lone-#{n}"

    for {id, title} <- [{ada, "Ada Referenced"}, {lone, "Lone Unreferenced"}] do
      {:ok, _} = Content.create_document(author, %{"doc_id" => id, "title" => title}, @dataset)
      {:ok, _} = Content.publish_document(id, author, @dataset)
    end

    for {id, title} <- [{"unp-post-1-#{n}", "Post One"}, {"unp-post-2-#{n}", "Post Two"}] do
      {:ok, _} =
        Content.create_document(
          post,
          %{
            "doc_id" => id,
            "title" => title,
            "content" => %{"author" => %{"_ref" => ada, "_type" => "reference"}}
          },
          @dataset
        )

      {:ok, _} = Content.publish_document(id, post, @dataset)
      # The guard reads `content_edges`, which a test write does not derive.
      {:ok, _} = Content.add_edge(id, ada, "author", dataset: @dataset, plugin_source: nil)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    raw = "desk-unpublish-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-unpublish", @dataset, ~w(read write admin), ws_id)
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

  defp open_studio(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.studio}/open/#{c.author}/#{id}")
    render_async(view, 5_000)
    assert poll(view, fn -> has_element?(view, "#editor-form") end)
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

  defp published?(c, id) do
    {_doc, _draft?, published?} = Content.fetch_doc_with_draft(c.author, id, @dataset)
    published?
  end

  # What the published post's author field holds.
  defp author_of(c, id) do
    {:ok, doc} = Content.get_document(id, c.post, @dataset)
    (doc.content || %{})["author"]
  end

  # How many times `needle` is in the dialog's markup.
  defp count(view, needle) do
    view |> element(@dialog) |> render() |> String.split(needle) |> length() |> Kernel.-(1)
  end

  test "a referenced document: the count in role=status, who refers in ul.used-in, three buttons",
       c do
    view = open(c, c.ada)
    render_hook(view, "unpublish", %{})

    assert has_element?(view, ~s(#{@dialog}[phx-hook="ModalFocus"] h2), "Unpublish document?")
    assert has_element?(view, ~s(#{@dialog} p strong), "Ada Referenced")

    assert count(view, ~s(role="status")) == 1

    assert has_element?(
             view,
             ~s(#{@dialog} [role="status"]),
             "2 documents refer to “Ada Referenced”"
           )

    assert count(view, "<li") == 2
    assert has_element?(view, ~s(#{@dialog} .used-in li:first-child), "Unp posts / author")
    assert has_element?(view, ~s(#{@dialog} .used-in li .t), "Post One")

    assert has_element?(
             view,
             @dialog,
             "You may not be able to unpublish “Ada Referenced” because the following documents refer to it:"
           )

    assert has_element?(
             view,
             @dialog,
             "If you unpublish this document, documents that refer to it will no longer be able to access it."
           )

    assert has_element?(view, ~s(#{@dialog} button[data-modal-focus]), "Cancel")
    assert has_element?(view, ~s(#{@dialog} button), "Disconnect references and unpublish")
    assert has_element?(view, ~s(#{@dialog} button.danger), "Unpublish anyway")
    # The Studio's own modal is not drawn on the desk.
    refute has_element?(view, "#unpublish-guard-dialog")

    # Opening it wrote nothing; Escape closes it and the document stays live.
    assert author_of(c, "unp-post-1-#{c.n}")["_ref"] == c.ada
    view |> element(@dialog) |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, @dialog)
    assert published?(c, c.ada)
  end

  test "Unpublish anyway unpublishes and leaves the references as they are", c do
    view = open(c, c.ada)
    render_hook(view, "unpublish", %{})

    view |> element(~s(#{@dialog} button.danger), "Unpublish anyway") |> render_click()

    refute has_element?(view, @dialog)
    refute published?(c, c.ada)
    assert author_of(c, "unp-post-1-#{c.n}")["_ref"] == c.ada
    assert author_of(c, "unp-post-2-#{c.n}")["_ref"] == c.ada
  end

  test "Disconnect references and unpublish takes the references out, only on that press", c do
    view = open(c, c.ada)
    render_hook(view, "unpublish", %{})
    assert author_of(c, "unp-post-1-#{c.n}")["_ref"] == c.ada

    view
    |> element(
      ~s(#{@dialog} button[phx-value-disconnect="true"]),
      "Disconnect references and unpublish"
    )
    |> render_click()

    refute has_element?(view, @dialog)
    refute published?(c, c.ada)
    assert author_of(c, "unp-post-1-#{c.n}") == nil
    assert author_of(c, "unp-post-2-#{c.n}") == nil
  end

  test "a document nobody refers to is asked about too: Unpublish now, or Cancel", c do
    view = open(c, c.lone)
    render_hook(view, "unpublish", %{})

    # Nothing happened yet.
    assert published?(c, c.lone)
    assert has_element?(view, ~s(#{@dialog} h2), "Unpublish document?")
    assert has_element?(view, @dialog, "Are you sure you want to unpublish “Lone Unreferenced”?")
    refute has_element?(view, ~s(#{@dialog} [role="status"]))
    refute has_element?(view, ~s(#{@dialog} .used-in))
    refute has_element?(view, ~s(#{@dialog} button), "Disconnect references and unpublish")

    view |> element(~s(#{@dialog} button[data-modal-focus]), "Cancel") |> render_click()
    refute has_element?(view, @dialog)
    assert published?(c, c.lone)

    render_hook(view, "unpublish", %{})
    view |> element(~s(#{@dialog} button.danger), "Unpublish now") |> render_click()

    refute has_element?(view, @dialog)
    refute published?(c, c.lone)
  end

  # Controls: the handler is shared with the old Studio.
  test "the old Studio unpublishes a document nobody refers to without asking", c do
    view = open_studio(c, c.lone)
    render_hook(view, "unpublish", %{})

    refute has_element?(view, "[role=dialog]")
    refute published?(c, c.lone)
  end

  test "the old Studio keeps its own guard modal and words", c do
    view = open_studio(c, c.ada)
    render_hook(view, "unpublish", %{})

    guard =
      ~s(#unpublish-guard-dialog.delete-modal[role="dialog"][data-test-id="unpublish-guard-modal"])

    assert has_element?(view, ~s(#{guard} #unpublish-guard-modal-title), "Unpublish document")

    assert has_element?(
             view,
             ~s(#{guard} [data-test-id="unpublish-ref"] .delete-ref-title),
             "Post One"
           )

    assert has_element?(view, ~s(#{guard} .delete-ref-meta), "#{c.post} / author")

    assert has_element?(
             view,
             ~s(#{guard} [data-test-id="confirm-unpublish-disconnect"]),
             "Disconnect references and unpublish"
           )

    assert has_element?(view, ~s(#{guard} [data-test-id="confirm-unpublish"]), "Unpublish anyway")
    assert view |> element(guard) |> render() =~ "is referenced by 2 documents."
    refute has_element?(view, "[data-desk-dialog]")
    refute has_element?(view, "ul.used-in")
    assert published?(c, c.ada)
  end
end
