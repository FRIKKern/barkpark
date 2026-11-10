defmodule BarkparkWeb.Studio.DeskEditorDocActionsTest do
  @moduledoc """
  Document actions that guard or navigate, run from the desk's editor pane
  (journeys J17, B07, J18, and J28's landing URL). The Studio's handlers
  navigate with `Shared.studio_path/4`, which prints the Studio's `nav_path`
  under the desk's base; the desk gives the editor a `nav_path` of
  `Tree.path_to_type(type) ++ [id]` (`DeskLive.edit/2`), so a navigation
  drops the panes to the document's left.

  Tests tagged `:desk_editor_red` fail on the current code on purpose; run
  `mix test <file> --only desk_editor_red` / `--exclude desk_editor_red`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author = "w2a_author_#{n}"
    post = "w2a_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author,
          "title" => "W2 action authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post,
          "title" => "W2 action posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [author]}
          ]
        },
        @dataset
      )

    ada = "w2a-ada-#{n}"
    lone = "w2a-lone-#{n}"
    one = "w2a-post-#{n}"

    for {id, title} <- [{ada, "Ada Referenced"}, {lone, "Lone Unreferenced"}] do
      {:ok, _} = Content.create_document(author, %{"doc_id" => id, "title" => title}, @dataset)
    end

    {:ok, _} =
      Content.create_document(
        post,
        %{
          "doc_id" => one,
          "title" => "Post One",
          "content" => %{"author" => %{"_ref" => ada, "_type" => "reference"}}
        },
        @dataset
      )

    # Published, as in the browser seed; the guards read `content_edges`,
    # which a test write does not derive, so the one edge is added by hand.
    for {type, id} <- [{author, ada}, {author, lone}, {post, one}] do
      {:ok, _} = Content.publish_document(id, type, @dataset)
    end

    {:ok, _} =
      Content.add_edge(one, ada, "references", dataset: @dataset, plugin_source: nil)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok, conn: conn, base: base, author: author, post: post, ada: ada, lone: lone, one: one}
  end

  defp admin(conn) do
    raw = "desk-w2-token-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()
    {:ok, _} = Auth.create_token(raw, "desk-w2", @dataset, ["read", "write", "admin"], ws.id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  defp poll(view, fun, tries \\ 25) do
    settle(view)

    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(view, fun, tries - 1)
    end
  end

  defp open(conn, url) do
    {:ok, view, _html} = live(admin(conn), url)
    settle(view)
    assert poll(view, fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  # The chain a doc is opened in when it was reached from a post's reference.
  defp deep(c, id), do: "#{c.post};#{c.one};#{id},type=#{c.author},parentRefPath=author"

  # ── J17: the delete guard ────────────────────────────────────────────────

  # WORKS (pinned): a referenced doc's Delete opens the guard, which names the
  # document and the field that use it.
  test "delete of a referenced doc opens the guard listing where it is used", c do
    view = open(c.conn, "#{c.base}/#{deep(c, c.ada)}")

    view |> element(~s([data-pane-editing] button[phx-click="delete-doc"])) |> render_click()

    assert has_element?(view, "#delete-modal-dialog[role=dialog]")
    assert has_element?(view, "#delete-modal-dialog .delete-ref-title", "Post One")
    assert has_element?(view, "#delete-modal-dialog .delete-ref-meta", c.post)
    assert has_element?(view, "#delete-modal-dialog [data-modal-focus]", "Cancel")

    view |> element("#delete-modal-dialog button[data-modal-focus]") |> render_click()
    refute has_element?(view, "#delete-modal-dialog")
    assert Content.fetch_doc_with_draft(c.author, c.ada, @dataset) |> elem(0)
  end

  # BROKEN: the delete lands on `<menu>;<type>` (path_to_type), dropping the
  # post and its list that the author was opened from.
  @tag :desk_editor_red
  test "deleting a doc deep in a chain lands on the chain without it", c do
    view = open(c.conn, "#{c.base}/#{deep(c, c.lone)}")

    render_hook(view, "delete-doc", %{})
    view |> element("#delete-modal-dialog button.btn-destructive") |> render_click()

    landed = assert_patch(view, 2_000)
    assert landed == "#{c.base}/#{c.post};#{c.one}"
  end

  # The plain delete at the top of the desk: the list pane is what is left,
  # and its row is gone.
  test "deleting a doc opened from its list lands on the list, without its row", c do
    view = open(c.conn, "#{c.base}/#{c.author};#{c.lone}")

    render_hook(view, "delete-doc", %{})
    view |> element("#delete-modal-dialog button.btn-destructive") |> render_click()

    landed = assert_patch(view, 2_000)
    assert String.starts_with?(landed, c.base <> "/")
    assert String.ends_with?(landed, c.author)

    assert poll(view, fn ->
             has_element?(view, ~s([data-pane-kind="list"] a[data-desk-row]), "Ada Referenced") and
               not has_element?(
                 view,
                 ~s([data-pane-kind="list"] a[data-desk-row]),
                 "Lone Unreferenced"
               )
           end)
  end

  # ── B07: the unpublish guard (WORKS, pinned) ─────────────────────────────

  test "unpublishing a referenced doc opens the guard listing its referencers", c do
    view = open(c.conn, "#{c.base}/#{deep(c, c.ada)}")

    view |> element(~s([data-pane-editing] button[phx-click="unpublish"])) |> render_click()

    assert has_element?(view, "#unpublish-guard-dialog[role=dialog]")

    assert has_element?(
             view,
             ~s(#unpublish-guard-dialog [data-test-id="unpublish-ref"]),
             "Post One"
           )

    view |> element("#unpublish-guard-dialog button[data-modal-focus]") |> render_click()
    refute has_element?(view, "#unpublish-guard-dialog")
    {_doc, _draft?, published?} = Content.fetch_doc_with_draft(c.author, c.ada, @dataset)
    assert published?
  end

  # ── J28: Duplicate's landing URL ─────────────────────────────────────────

  # BROKEN: the copy opens at `<menu>;<type>;<copy>`: the chain it was made
  # from (post list, post) is dropped.
  @tag :desk_editor_red
  test "duplicating a doc deep in a chain opens the copy in that chain", c do
    view = open(c.conn, "#{c.base}/#{deep(c, c.lone)}")

    render_hook(view, "duplicate-doc", %{})

    landed = assert_patch(view, 2_000)

    assert String.starts_with?(landed, "#{c.base}/#{c.post};#{c.one};"),
           "the copy opened at #{landed}"
  end

  # ── "View blast radius" ──────────────────────────────────────────────────

  # BROKEN: the Studio's `graph/<id>` path is printed as the desk chain
  # `graph;<id>`: the chain is dropped and pane 1 says there is no type
  # named "graph".
  @tag :desk_editor_red
  test "view blast radius keeps the desk chain", c do
    view = open(c.conn, "#{c.base}/#{deep(c, c.ada)}")

    render_hook(view, "view-graph", %{})
    landed = assert_patch(view, 2_000)

    assert String.starts_with?(landed, "#{c.base}/#{c.post};#{c.one};"),
           "blast radius landed on #{landed}"
  end

  # ── J18: a new document from the desk ────────────────────────────────────

  # NOT REACHABLE in the desk (its list panes draw no "+"). What the Studio's
  # own "new-document" does when the desk hosts the editor: it lands on
  # `<menu>;<type>;<open doc>;<new id>` with no `type=`, so the new doc is an
  # untyped read-only pane and no editor opens.
  @tag :desk_editor_red
  test "new-document from the desk opens the new doc in the editor after its list", c do
    view = open(c.conn, "#{c.base}/#{c.post};#{c.one}")

    render_hook(view, "new-document", %{"type" => c.post})
    landed = assert_patch(view, 2_000)
    settle(view)

    assert landed =~ ~r"^#{Regex.escape(c.base)}/#{c.post};#{c.post}-[0-9a-f]+",
           "the new document landed on #{landed}"

    assert poll(view, fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
  end
end
