defmodule BarkparkWeb.Studio.DeskEditorHistoryTest do
  @moduledoc """
  Journeys J15 (review changes: diff, revert all) and J16 (history, restore)
  in the desk's editor pane (`DeskLive`, the last document of the chain).

  Measured in a browser first (editing-w4 probe): the diff and the history
  dialog work inside the pane. "Discard draft" (revert all) asks the Studio
  for the same document again: the desk keeps its URL and its chain, and the
  editor reloads in place with the published values (`EditorHost`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    author_type = "w4_author_#{n}"
    post_type = "w4_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => author_type,
          "title" => "W4 authors #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "bio", "title" => "Bio", "type" => "text"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => post_type,
          "title" => "W4 posts #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "summary", "title" => "Summary", "type" => "text"},
            %{
              "name" => "author",
              "title" => "Author",
              "type" => "reference",
              "to" => [author_type]
            }
          ]
        },
        @dataset
      )

    author = "w4a-#{n}"
    post = "w4p-#{n}"

    published_with_draft!(
      author_type,
      author,
      %{"title" => "Ada published", "content" => %{"bio" => "Published bio"}},
      %{"title" => "Ada draft", "content" => %{"bio" => "Draft bio"}}
    )

    ref = %{"_ref" => author, "_type" => "reference"}

    published_with_draft!(
      post_type,
      post,
      %{
        "title" => "Post published",
        "content" => %{"summary" => "Published sum", "author" => ref}
      },
      %{"title" => "Post draft", "content" => %{"summary" => "Draft sum", "author" => ref}}
    )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"

    {:ok,
     conn: admin(conn),
     base: base,
     post_type: post_type,
     author_type: author_type,
     post: post,
     author: author}
  end

  defp published_with_draft!(type, id, published, draft) do
    {:ok, _} = Content.create_document(type, Map.put(published, "doc_id", id), @dataset)
    {:ok, _} = Content.publish_document(id, type, @dataset)

    {:ok, _} =
      Content.upsert_document(type, Map.put(draft, "doc_id", Content.draft_id(id)), @dataset)
  end

  defp admin(conn) do
    raw = "w4-desk-history-" <> Ecto.UUID.generate()
    ws = Tenancy.get_default_workspace()

    {:ok, _} =
      Auth.create_token(raw, "w4-desk-history", @dataset, ["read", "write", "admin"], ws.id)

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp settle(view), do: render_async(view, 5_000)

  # The editor pane's field shows `value` (an input's value attribute, or a
  # textarea's text). Polled: a pane's read and the editor load are async.
  defp editor_shows?(view, field, value, tries \\ 25) do
    shown =
      has_element?(
        view,
        ~s([data-pane-editing] #editor-form input[name="doc[#{field}]"][value="#{value}"])
      ) or
        has_element?(
          view,
          ~s([data-pane-editing] #editor-form textarea[name="doc[#{field}]"]),
          value
        )

    cond do
      shown ->
        true

      tries > 0 ->
        Process.sleep(100)
        settle(view)
        editor_shows?(view, field, value, tries - 1)

      true ->
        false
    end
  end

  describe "J15 review changes" do
    test "Diff shows draft against published inside the editor pane, and toggles back", ctx do
      {:ok, view, _} = live(ctx.conn, "#{ctx.base}/#{ctx.post_type};#{ctx.post}")
      settle(view)
      assert editor_shows?(view, "summary", "Draft sum")

      view
      |> element(~s([data-pane-editing] [data-test-id="draft-diff-toggle"]))
      |> render_click()

      assert has_element?(view, ~s([data-pane-editing] [data-test-id="draft-diff"]))

      assert has_element?(
               view,
               ~s([data-pane-editing] [data-test-id="draft-diff-status-summary"]),
               "Changed"
             )

      view
      |> element(~s([data-pane-editing] [data-test-id="draft-diff-toggle"]))
      |> render_click()

      refute has_element?(view, ~s([data-test-id="draft-diff"]))
    end

    # On the old code the editor kept the discarded draft (title "Post draft")
    # until a reload: Discard.confirm_discard patches to the same document and
    # `EditorHost.follow/3` keeps the editor of the same target.
    test "Discard draft shows the published document in the pane", ctx do
      {:ok, view, _} = live(ctx.conn, "#{ctx.base}/#{ctx.post_type};#{ctx.post}")
      settle(view)
      assert editor_shows?(view, "title", "Post draft")

      BarkparkWeb.EditorPost.press(view, "discard-draft", %{})
      assert has_element?(view, ~s([data-test-id="discard-draft-modal"]))
      BarkparkWeb.EditorPost.press(view, "confirm-discard", %{})

      # The store is right...
      assert {:error, _} =
               Content.get_document(Content.draft_id(ctx.post), ctx.post_type, @dataset)

      # ...the pane must follow it.
      assert editor_shows?(view, "title", "Post published"),
             "the desk editor still shows the discarded draft after Discard draft"

      refute has_element?(view, ~s([data-pane-editing] [data-test-id="discard-draft"])),
             "Discard draft is still offered: the editor still thinks it is on a draft"
    end

    # On the old code, discarding the draft of a document opened from a
    # reference patched to the Studio's own path for its type, dropping the
    # post that referenced it. The desk now sends no patch at all.
    test "Discard draft keeps the pane chain to the left of the document", ctx do
      chain =
        "#{ctx.post_type};#{ctx.post};#{ctx.author},type=#{ctx.author_type},parentRefPath=author"

      {:ok, view, _} = live(ctx.conn, "#{ctx.base}/#{chain}")
      settle(view)
      assert editor_shows?(view, "bio", "Draft bio")

      BarkparkWeb.EditorPost.press(view, "discard-draft", %{})
      BarkparkWeb.EditorPost.press(view, "confirm-discard", %{})
      settle(view)

      %{proxy: {ref, topic, _}} = view

      refute_received {^ref, {:patch, ^topic, _}},
                      "discard patched the desk away from #{ctx.base}/#{chain}"

      assert has_element?(view, ~s([data-pane-index="2"][data-pane-kind="doc"]))
      assert has_element?(view, ~s([data-pane-index="3"][data-pane-editing]))
      assert editor_shows?(view, "bio", "Published bio"), "the editor still shows the draft bio"
    end
  end

  # J16 as the TanStack Studio has it (`HistoryPanel.tsx`): History is an
  # inspector beside the form, not a dialog. On the old code the menu's
  # History opened the Studio's dialog, and the URL's inspector drew nothing.
  describe "J16 history inspector" do
    @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"

    defp at(ctx, params \\ ""), do: "#{ctx.base}/#{ctx.post_type};#{ctx.post}#{params}"

    defp revisions(ctx), do: Content.list_revisions(ctx.post, ctx.post_type, @dataset, limit: 30)

    test "the menu's History opens the inspector, a list of the document's revisions", ctx do
      {:ok, view, _} = live(ctx.conn, at(ctx))
      settle(view)

      item =
        view
        |> element(
          ~s([data-pane-editing] [role="menu"][id$="-editor-actions"] [data-desk-doc-action="show-history"])
        )
        |> render()

      assert item =~ "inspect=sanity%2Fstructure%2Fhistory",
             "History is no patch to the inspector: #{item}"

      refute item =~ ~s(phx-click="show-history"), "History still opens the Studio's dialog"

      {:ok, view, _} = live(ctx.conn, at(ctx, @history))
      settle(view)

      list =
        ~s([data-pane-editing] aside[aria-label="History"] ul[aria-label="Document revisions"])

      assert has_element?(view, list), "no list named Document revisions in a History inspector"

      assert has_element?(view, ~s(#{list} li button[aria-current="true"])),
             "the newest entry is not the current one"

      assert has_element?(view, "#{list} li button", "Published")

      assert has_element?(
               view,
               ~s([data-pane-editing] [role="tab"][aria-selected="true"]),
               "History"
             )

      refute has_element?(view, "[data-pane-editing] [data-desk-left-out]")
      refute has_element?(view, "#history-modal-dialog")
    end

    test "an old revision shows read-only at its URL, writes nothing, and Confirm restores it",
         ctx do
      rev = Enum.find(revisions(ctx), &(&1.action == "publish"))
      url = at(ctx, @history <> ",rev=#{rev.id}")
      {:ok, view, _} = live(ctx.conn, url)
      settle(view)

      assert editor_shows?(view, "title", "Post published"), "the form does not show the revision"
      assert has_element?(view, ~s([data-pane-editing] fieldset[disabled] #editor-form))

      assert has_element?(
               view,
               "[data-pane-editing] [data-desk-revision-footer]",
               "Revert to revision"
             )

      refute has_element?(view, "[data-pane-editing] [data-desk-publish]")

      # A post from the shown form is dropped: the draft keeps its title.
      BarkparkWeb.EditorPost.change(view, %{"doc" => %{"title" => "Typed over a revision"}})
      settle(view)
      {:ok, draft} = Content.get_document(Content.draft_id(ctx.post), ctx.post_type, @dataset)
      assert draft.title == "Post draft", "the revision's form wrote the draft"

      BarkparkWeb.EditorPost.press_on(view, element(view, "[data-desk-revert-confirm]"))

      {:ok, draft} = Content.get_document(Content.draft_id(ctx.post), ctx.post_type, @dataset)
      assert draft.title == "Post published", "Confirm did not write the revision back"
      assert_patch(view, at(ctx, @history))
    end

    test "a revision of another document is not shown", ctx do
      other = ctx.author |> Content.list_revisions(ctx.author_type, @dataset, limit: 1) |> hd()
      {:ok, view, _} = live(ctx.conn, at(ctx, @history <> ",rev=#{other.id}"))
      settle(view)

      assert has_element?(view, "[data-pane-editing] [data-desk-revision-missing]")
      refute has_element?(view, "[data-pane-editing] [data-desk-revision-footer]")
      refute has_element?(view, "[data-pane-editing] #editor-form")
    end

    test "the footer's status opens Review changes, the group tabs waiting", ctx do
      {:ok, view, _} = live(ctx.conn, at(ctx))
      settle(view)

      status =
        view |> element("[data-pane-editing] .doc-footer [data-desk-footer-status]") |> render()

      refute status =~ "disabled", "the footer's status is still a disabled button"
      assert status =~ "changesInspectorTab=review", "the status opens no Review changes"

      {:ok, view, _} =
        live(
          ctx.conn,
          at(
            ctx,
            ",since=@lastPublished,changesInspectorTab=review,inspect=sanity%2Fstructure%2Fhistory"
          )
        )

      settle(view)

      assert has_element?(
               view,
               ~s([data-pane-editing] aside[aria-label="History"] [role="tab"][aria-selected="true"]),
               "Review changes"
             )

      assert has_element?(view, ~s([data-pane-editing][data-desk-inspecting]))
    end
  end

  describe "J16 history dialog (the Studio's own, outside the desk's menu)" do
    test "History opens in the pane, and restoring a revision loads it into the editor", ctx do
      {:ok, view, _} = live(ctx.conn, "#{ctx.base}/#{ctx.post_type};#{ctx.post}")
      settle(view)

      view
      |> element(~s{[data-pane-editing] button[phx-click="show-history"]:not([role="menuitem"])})
      |> render_click()

      assert has_element?(view, "[data-pane-editing] #history-modal-dialog[role=dialog]")

      # The oldest revision is the first published state.
      [rev | _] =
        Content.list_revisions(ctx.post, ctx.post_type, @dataset, limit: 30) |> Enum.reverse()

      BarkparkWeb.EditorPost.press_on(
        view,
        element(
          view,
          ~s(#history-modal-dialog button[phx-click="restore-revision"][phx-value-id="#{rev.id}"])
        )
      )

      refute has_element?(view, "#history-modal-dialog")
      assert editor_shows?(view, "title", "Post published")
    end

    test "Escape closes the history dialog", ctx do
      {:ok, view, _} = live(ctx.conn, "#{ctx.base}/#{ctx.post_type};#{ctx.post}")
      settle(view)

      view
      |> element(~s{[data-pane-editing] button[phx-click="show-history"]:not([role="menuitem"])})
      |> render_click()

      assert has_element?(view, "#history-modal-dialog")
      render_keydown(view, "close-history", %{"key" => "Escape"})
      refute has_element?(view, "#history-modal-dialog")
    end
  end
end
