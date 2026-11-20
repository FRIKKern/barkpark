defmodule BarkparkWeb.Studio.DeskRemoteSavePathsTest do
  @moduledoc """
  task-6b336810643b1a70 (round 2 review of #27622): the desk footer's
  "Updated by another user" (`Desk.RemoteSave`), on every write path and
  every load.

  - Every desk write is this tab's save: a tree codelist's pick and an image
    pick are written from a message the page sends itself, not an event, and
    another editor's save that replaces them is still named.
  - Only the user's values count: another editor's Publish of the draft this
    tab typed loses nothing, so the footer says "Last published just now".
  - A discard elsewhere reloads the published document: a tab that never
    typed says "Last published", never nothing.
  - The record starts again when the document is opened again: a loss
    marked before is not named late.
  - What this tab saved is read from the write, not from the post: a
    Restore from History (no save state, no `_target`) and the form's
    submit (Enter: `save` with no `_target`) count too.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @status ~s([data-pane-editing] .dk-edit-footer [data-desk-footer-status] .save-state-text)
  @publish ~s([data-pane-editing] [data-desk-publish])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rsp_#{n}"
    doc_id = "rsp-#{n}"
    other_id = "rsp-other-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Remote save paths #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"},
            %{"name" => "day", "title" => "Day", "type" => "date"},
            %{
              "name" => "stage",
              "title" => "Stage",
              "type" => "string",
              "options" => %{"list" => ["draft", "review", "published"]}
            },
            %{"name" => "cover", "title" => "Cover", "type" => "image"}
          ]
        },
        @dataset
      )

    content = %{"excerpt" => "First", "day" => "2026-01-01", "stage" => "draft"}

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Hello world", "content" => content},
        @dataset
      )

    {:ok, _} =
      Content.create_document(type, %{"doc_id" => other_id, "title" => "Other"}, @dataset)

    Application.put_env(:barkpark, :desk_saved_ms, 100)
    on_exit(fn -> Application.delete_env(:barkpark, :desk_saved_ms) end)

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-remote-save-paths-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-rsp", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     desk: "#{base}/_desk/#{type};#{doc_id}",
     other: "#{base}/_desk/#{type};#{other_id}",
     type: type,
     doc_id: doc_id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.desk)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..300, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp status(view), do: view |> element(@status) |> render() |> strip()
  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  # The footer's words once this tab's "Saved" is over and the frames are in.
  defp settled(view) do
    Process.sleep(250)
    render(view)
    status(view)
  end

  defp form_of(view), do: :sys.get_state(view.pid).socket.assigns.editor_form

  defp send_post(view, target, changes) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", target],
      "doc" => Map.merge(form_of(view), changes),
      "_bp_seen" => Jason.encode!(%{})
    })
  end

  defp told(view) do
    render(view)
    assert_push_event(view, "bp:form-remote-values", %{values: _}, 2_000)
  end

  defp stored(c, key) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    Map.put(doc.content || %{}, "title", doc.title)[key]
  end

  # A draft over the created document, so its first revision is the
  # created one.
  defp draft(c, content, title \\ "Hello world") do
    content =
      Map.merge(%{"excerpt" => "First", "day" => "2026-01-01", "stage" => "draft"}, content)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.doc_id, "title" => title, "content" => content},
        @dataset
      )
  end

  # The History dialog's Restore of the document's first revision.
  defp restore_first(view, c) do
    rev = Content.list_revisions(c.doc_id, c.type, @dataset, limit: 30) |> List.last()
    EditorPost.press(view, "restore-revision", %{"id" => rev.id})
    render(view)
  end

  # The pick `TreeCodelistField.pick/3` sends the page.
  defp tree_pick(view, code) do
    send(
      view.pid,
      {:tree_codelist_pick,
       %{name: "doc[stage]", value: code, press: EditorPost.named(view, %{"code" => code})}}
    )

    render(view)
  end

  describe "a write the page sends itself is this tab's save" do
    test "a tree codelist's pick replaced by another editor is named", c do
      a = open(c)
      b = open(c)
      tree_pick(a, "review")
      assert eventually(fn -> stored(c, "stage") == "review" end)

      told(b)
      send_post(b, "stage", %{"stage" => "published"})
      assert stored(c, "stage") == "published"

      assert settled(a) == "Updated by another user"
    end

    test "a tree codelist's pick says Saved, as a typed save does", c do
      Application.put_env(:barkpark, :desk_saved_ms, 5_000)
      a = open(c)
      tree_pick(a, "review")
      assert eventually(fn -> status(a) == "Saved" end), status(a)
    end

    test "an image pick replaced by another editor is named", c do
      a = open(c)
      b = open(c)

      render_hook(
        a,
        "select-media",
        EditorPost.named(a, %{"field" => "cover", "url" => "/media/files/a.png"})
      )

      assert eventually(fn -> stored(c, "cover") == "/media/files/a.png" end)

      told(b)
      send_post(b, "cover", %{"cover" => "/media/files/b.png"})
      assert stored(c, "cover") == "/media/files/b.png"

      assert settled(a) == "Updated by another user"
    end
  end

  describe "a write is read from the write itself, not from the post" do
    # A Restore writes through `Content`: the save state stays as it was, and
    # the restored text has no `_target`.
    test "a Restore of the day on a fresh open, then another editor's day", c do
      draft(c, %{"day" => "2026-05-05"})
      a = open(c)
      b = open(c)
      restore_first(a, c)
      assert stored(c, "day") == "2026-01-01"

      told(b)
      send_post(b, "day", %{"day" => "2026-07-07"})
      assert stored(c, "day") == "2026-07-07"

      assert settled(a) == "Updated by another user"
    end

    test "a Restore of the title on a fresh open, then another editor's post with no base", c do
      draft(c, %{}, "Hello there")
      a = open(c)
      b = open(c)
      restore_first(a, c)
      assert stored(c, "title") == "Hello world"

      told(b)
      send_post(b, "title", %{"title" => "Hello there B"})
      assert stored(c, "title") == "Hello there B"

      assert settled(a) == "Updated by another user"
    end

    test "typing, then a Restore of the title: the restore is what is kept", c do
      a = open(c)
      b = open(c)
      send_post(a, "title", %{"title" => "Hello there"})
      told(b)
      restore_first(a, c)
      assert stored(c, "title") == "Hello world"

      told(b)
      send_post(b, "title", %{"title" => "Hello there B"})
      assert stored(c, "title") == "Hello there B"

      assert settled(a) == "Updated by another user"
    end

    # Enter in a form whose only text input is the title submits it: the page
    # sends `save` alone, with no `_target` (LiveView drops the debounced
    # autosave).
    test "the form's submit (Enter), then another editor's post with no base", c do
      a = open(c)
      b = open(c)

      a
      |> element("#editor-form")
      |> render_submit(%{
        "doc" => Map.merge(form_of(a), %{"title" => "Hello world A7"}),
        "_bp_seen" => "{}"
      })

      assert stored(c, "title") == "Hello world A7"

      told(b)
      send_post(b, "title", %{"title" => "Hello world B3"})
      assert stored(c, "title") == "Hello world B3"

      assert settled(a) == "Updated by another user"
    end
  end

  describe "only the user's values count" do
    test "another editor publishes the draft this tab typed: Last published", c do
      {:ok, _} = Content.publish_document(c.doc_id, c.type, @dataset)
      a = open(c)
      b = open(c)
      send_post(a, "title", %{"title" => "Hello from A"})
      told(b)
      assert settled(a) == "Edited just now"

      EditorPost.press_on(b, element(b, @publish))
      assert {:ok, %{title: "Hello from A"}} = Content.get_document(c.doc_id, c.type, @dataset)

      assert settled(a) == "Last published just now"
      assert has_element?(a, @publish <> "[disabled]")
      assert settled(b) == "Last published just now"
    end

    test "the same, published by another client", c do
      {:ok, _} = Content.publish_document(c.doc_id, c.type, @dataset)
      a = open(c)
      send_post(a, "day", %{"day" => "2026-02-15"})
      assert settled(a) == "Edited just now"

      {:ok, _} = Content.publish_document(c.doc_id, c.type, @dataset)

      assert settled(a) == "Last published just now"
    end
  end

  test "a discard elsewhere: a tab that never typed says Last published", c do
    {:ok, _} = Content.publish_document(c.doc_id, c.type, @dataset)
    a = open(c)
    b = open(c)
    send_post(a, "title", %{"title" => "Hello from A"})
    told(b)
    assert settled(b) == "Edited just now"

    {:ok, _} = Content.discard_draft(c.doc_id, c.type, @dataset)

    assert settled(b) == "Last published just now"
    assert has_element?(b, @publish <> "[disabled]")
  end

  test "opened again, a loss marked before is not named late", c do
    a = open(c)
    b = open(c)
    send_post(a, "day", %{"day" => "2026-02-15"})
    send_post(b, "day", %{"day" => "2026-03-03"})
    assert settled(a) == "Updated by another user"

    render_patch(a, c.other)
    render_async(a, 5_000)
    render_patch(a, c.desk)
    render_async(a, 5_000)
    assert eventually(fn -> has_element?(a, "[data-pane-editing] #editor-form") end)

    # A clean save elsewhere: nothing of A's since the document was opened again.
    send_post(b, "excerpt", %{"excerpt" => "B again"})
    assert settled(a) == "Edited just now"
  end
end
