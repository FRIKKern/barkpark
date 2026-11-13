defmodule BarkparkWeb.Studio.DeskEditorDocActionsTest do
  @moduledoc """
  Document actions that guard or navigate, run from the desk's editor pane
  (journeys J17, B07, J18, J28's landing URL, D06). The Studio's handlers
  navigate with `Shared.studio_path/4`, which prints the Studio's `nav_path`
  under the desk's base; `EditorHost` reads that path back against the
  Studio path it handed over and the desk's chain, so a navigation keeps the
  panes the document was opened from.
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

    view
    |> element(~s{[data-pane-editing] button[phx-click="delete-doc"]:not([role="menuitem"])})
    |> render_click()

    assert has_element?(view, "#delete-modal-dialog[role=dialog]")
    assert has_element?(view, "#delete-modal-dialog .delete-ref-title", "Post One")
    assert has_element?(view, "#delete-modal-dialog .delete-ref-meta", c.post)
    assert has_element?(view, "#delete-modal-dialog [data-modal-focus]", "Cancel")

    view |> element("#delete-modal-dialog button[data-modal-focus]") |> render_click()
    refute has_element?(view, "#delete-modal-dialog")
    assert Content.fetch_doc_with_draft(c.author, c.ada, @dataset) |> elem(0)
  end

  # The delete lands on the chain the author was opened from, without it.
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

    view
    |> element(~s{[data-pane-editing] button[phx-click="unpublish"]:not([role="menuitem"])})
    |> render_click()

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

  # The copy takes the original's place in the chain it was made from (post
  # list, post), typed, and opens in the editor.
  test "duplicating a doc deep in a chain opens the copy in that chain", c do
    view = open(c.conn, "#{c.base}/#{deep(c, c.lone)}")

    render_hook(view, "duplicate-doc", %{})

    landed = assert_patch(view, 2_000)

    copy =
      ~r"^#{Regex.escape("#{c.base}/#{c.post};#{c.one};#{c.author}-")}[0-9a-f]+,type=#{c.author}$"

    assert landed =~ copy, "the copy opened at #{landed}"
    refute landed =~ c.lone, "the copy opened at #{landed}, still naming the original"

    assert poll(view, fn ->
             has_element?(view, ~s|[data-pane-editing] input[name="doc[title]"][value*="(copy)"]|)
           end),
           "the copy at #{landed} did not open in the editor"
  end

  # ── "View blast radius" ──────────────────────────────────────────────────

  # The desk has no graph pane: blast radius leaves for the Studio's own
  # graph page (a navigate, so Back returns to the chain) instead of printing
  # `graph;<id>` as a desk chain ("There is no document type named graph").
  test "view blast radius opens the Studio's graph page", c do
    view = open(c.conn, "#{c.base}/#{deep(c, c.ada)}")
    studio = String.replace_suffix(c.base, "/_desk", "")

    result = render_hook(view, "view-graph", %{})

    assert {:error, {:live_redirect, %{kind: :push, to: to}}} = result
    assert to == "#{studio}/graph/#{c.ada}", "blast radius went to #{to}"
  end

  # ── J18: a new document from the desk ────────────────────────────────────

  # NOT REACHABLE in the desk yet (its list panes draw no "+"). The Studio's
  # own "new-document", hosted by the desk: the new doc takes the open doc's
  # place after the list it belongs to, typed, and opens in the editor.
  test "new-document from the desk opens the new doc in the editor after its list", c do
    view = open(c.conn, "#{c.base}/#{c.post};#{c.one}")

    render_hook(view, "new-document", %{"type" => c.post})
    landed = assert_patch(view, 2_000)
    settle(view)

    assert landed =~ ~r"^#{Regex.escape(c.base)}/#{c.post};#{c.post}-[0-9a-f]+",
           "the new document landed on #{landed}"

    assert poll(view, fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
  end

  # A "+" names the pane it was pressed in (`desk-pane`): the new doc opens
  # right after that pane, the panes to its right are replaced.
  test "new-document with a desk-pane opens the new doc after that pane", c do
    view = open(c.conn, "#{c.base}/#{deep(c, c.lone)}")

    render_hook(view, "new-document", %{"type" => c.post, "desk-pane" => "1"})
    landed = assert_patch(view, 2_000)

    assert landed =~ ~r"^#{Regex.escape(c.base)}/#{c.post};#{c.post}-[0-9a-f]+$",
           "the new document landed on #{landed}"
  end

  # ── D06: a document by type and id opens as the next pane ────────────────

  # Moved from desk_editor_paper_test.exs. The canvas hook answers a
  # wikilink's "Open" (and the backlinks panel its rows) with `open-backlink`,
  # which the Studio patches to its reserved `["open", type, slug]` path. In
  # the desk the target opens in the next pane, the paper stays left of it.
  test "D06: a wikilink's Open opens the target beside the paper", c do
    prev = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if prev,
        do: System.put_env("BARKPARK_PAPER_CANVAS", prev),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {src, target} = papers!()
    {:ok, view, _} = live(admin(c.conn), "#{c.base}/paper;#{src}")
    settle(view)

    render_hook(view, "open-backlink", %{"slug" => target, "type" => "paper"})
    to = view |> assert_patch(2_000) |> URI.decode()

    refute String.contains?(to, "/_desk/open;"),
           "open-backlink patched to #{to}: the reserved Studio path leaked into the desk URL"

    assert to == "#{c.base}/paper;#{src};#{target}",
           "open-backlink patched to #{to}: the target is not the pane after the paper"
  end

  # A paper whose wikilink names a second paper.
  defp papers! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    n = System.unique_integer([:positive])
    src = "w4-desk-src-#{n}"
    target = "w4-desk-tgt-#{n}"
    para = fn id, kids -> %{"id" => id, "type" => "paragraph", "content" => kids} end
    text = fn v -> %{"type" => "text", "value" => v} end

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: target,
          dataset: @dataset,
          title: "Glacier almanac #{n}",
          blocks: [para.("t-1", [text.("Moraines and crevasses, measured yearly.")])]
        })
      )

    wikilink = %{
      "type" => "wikilink",
      "target" => "Glacier almanac #{n}",
      "children" => [text.("the almanac")]
    }

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: src,
          dataset: @dataset,
          title: "Harbour crane journal #{n}",
          blocks: [para.("p-1", [text.("See "), wikilink])]
        })
      )

    {src, target}
  end
end
