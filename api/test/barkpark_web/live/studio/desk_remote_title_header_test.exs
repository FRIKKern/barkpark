defmodule BarkparkWeb.Studio.DeskRemoteTitleHeaderTest do
  @moduledoc """
  task-42a6f063263338f6: B saves a new title. A's title field and list row
  showed it, but A's pane header (and the browser tab, `page_title`) kept
  the old one: the header names `editor_doc`, which stays this tab's own
  row after a remote save (the stale-post guard, task-a4ded0be5c8ec3cb).
  The header names the newest stored version this tab has seen, as
  TanStack's DocumentPane follows the document.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @header "[data-pane-editing] > .pane-header > .pane-header-title"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "remote_title_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Remote titles",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "remote-title-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Doc 7", "content" => %{"notes" => "n0"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "remote-title-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "remote-title", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     path: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}",
     type: type,
     id: id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "[data-pane-editing] #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The header's text, tags stripped.
  defp header(view) do
    view
    |> element(@header)
    |> render()
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  # The big title over the form and the page's sr-only h1 (`Editor`).
  defp headings(view) do
    for sel <- ["[data-pane-editing] .dk-big-title", "[data-pane-editing] h1.sr-only"] do
      view |> element(sel) |> render() |> String.replace(~r/<[^>]+>/, "") |> String.trim()
    end
  end

  defp posts(view, key, value) do
    form = Map.take(assigns(view).editor_form, ~w(title notes))

    view
    |> element("[data-pane-editing] #editor-form")
    |> render_change(%{"_target" => ["doc", key], "doc" => Map.put(form, key, value)})
  end

  test "B saves a new title: A's pane header and tab title show it", c do
    a = open(c)
    b = open(c)
    assert header(a) == "Doc 7"

    posts(b, "title", "Doc 7 B1")

    assert eventually(fn -> assigns(a).editor_form["title"] == "Doc 7 B1" end)
    assert eventually(fn -> header(a) == "Doc 7 B1" end)
    assert assigns(a).page_title == "Doc 7 B1"
  end

  test "the same while A holds another field unsaved", c do
    a = open(c)
    b = open(c)

    :sys.replace_state(a.pid, fn state ->
      socket = state.socket

      assigns =
        Map.merge(socket.assigns, %{
          editor_dirty: true,
          editor_unsaved_keys: MapSet.new(["notes"]),
          editor_form: Map.put(socket.assigns.editor_form, "notes", "n0, mine")
        })

      %{state | socket: %{socket | assigns: assigns}}
    end)

    posts(b, "title", "Doc 7 B1")

    assert eventually(fn -> header(a) == "Doc 7 B1" end)
    assert assigns(a).editor_form["notes"] == "n0, mine"
  end

  # The stale-post guard stays: `editor_doc` is still A's own row, so a post
  # that left A's page before B's save does not write A's old title back.
  test "control: A's post of another field after B's title keeps B's title", c do
    a = open(c)
    b = open(c)
    posts(b, "title", "Doc 7 B1")
    assert eventually(fn -> header(a) == "Doc 7 B1" end)
    assert assigns(a).editor_doc.title == "Doc 7"

    a
    |> element("[data-pane-editing] #editor-form")
    |> render_change(%{
      "_target" => ["doc", "notes"],
      "doc" => %{"title" => "Doc 7", "notes" => "n0 A"}
    })

    assert eventually(fn ->
             {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
             doc.content["notes"] == "n0 A"
           end)

    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    assert doc.title == "Doc 7 B1"
    assert eventually(fn -> header(a) == "Doc 7 B1" end)
  end

  # #28322 review: the big title and the h1 named `editor_doc` too.
  test "B saves a new title: A's big title and h1 show it", c do
    a = open(c)
    b = open(c)
    assert headings(a) == ["Doc 7", "Doc 7"]

    posts(b, "title", "Doc 7 B1")

    assert eventually(fn -> headings(a) == ["Doc 7 B1", "Doc 7 B1"] end)
    assert header(a) == "Doc 7 B1"
  end

  test "a restore names the restored title", c do
    a = open(c)
    [first | _] = Content.list_revisions(c.id, c.type, @dataset, limit: 30) |> Enum.reverse()
    posts(a, "title", "Doc 7 A1")
    assert eventually(fn -> header(a) == "Doc 7 A1" end)

    BarkparkWeb.EditorPost.press(a, "restore-revision", %{"id" => first.id})

    assert eventually(fn ->
             {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
             doc.title == "Doc 7"
           end)

    assert eventually(fn -> header(a) == "Doc 7" end)
    assert headings(a) == ["Doc 7", "Doc 7"]
    assert assigns(a).page_title == "Doc 7"
  end

  # TanStack names its cached doc, which carries this editor's unsent values
  # (edits.ts `overlay`): a refused title is A's own in the header, under
  # B's save too.
  @long "Doc 7 " <> String.duplicate("x", 300)

  test "A's refused title is named, also after B's save", c do
    a = open(c)
    b = open(c)
    posts(a, "title", @long)

    assert eventually(fn ->
             MapSet.member?(assigns(a).editor_unsaved_keys || MapSet.new(), "title")
           end)

    assert header(a) == @long
    assert headings(a) == [@long, @long]

    posts(b, "notes", "n0 B")
    assert eventually(fn -> assigns(a).editor_form["notes"] == "n0 B" end)
    assert header(a) == @long
    assert assigns(a).page_title == @long
  end

  # #28322 review, round 2: every place names the stored title the field
  # shows, after a reload of the row through `handle_params` or a publish.
  defp agree!(view, c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)

    assert eventually(fn ->
             header(view) == doc.title and headings(view) == [doc.title, doc.title] and
               assigns(view).page_title == doc.title and
               assigns(view).editor_form["title"] == doc.title
           end),
           "#{inspect({header(view), headings(view), assigns(view).editor_form["title"], doc.title})}"
  end

  defp press(view, event), do: BarkparkWeb.EditorPost.press(view, event, %{})

  # A publishes and edits the title; B renames the draft; A's page has B's
  # draft frame.
  defp b_renamed_draft(c) do
    a = open(c)
    press(a, "publish")

    assert eventually(fn ->
             match?({:ok, _}, Content.get_document(c.id, c.type, @dataset))
           end)

    posts(a, "title", "A draft")
    b = open(c)
    posts(b, "title", "B draft")
    assert eventually(fn -> header(a) == "B draft" end)
    a
  end

  test "discard after B renamed the draft names the published title", c do
    a = b_renamed_draft(c)

    press(a, "discard-draft")
    press(a, "confirm-discard")

    assert eventually(fn -> assigns(a).editor_form["title"] == "Doc 7" end)
    agree!(a, c)
  end

  # task-e82f6c625819d4f5: the row A reads back is older than B's last frame
  # and of the other variant (B's draft is gone), so the frame must not name
  # the page because it is newer: it counts only over the row it arrived on
  # (`Lifecycle.base_doc/1`, `editor_store_over`). Comparing times alone named
  # the dead draft's title.
  test "B discards the draft it renamed, A reloads: the published title is named", c do
    a = b_renamed_draft(c)
    assert {:ok, _} = Content.discard_draft(c.id, c.type, @dataset)
    assert {:error, :not_found} == Content.get_document("drafts." <> c.id, c.type, @dataset)

    press(a, "reload-remote-doc")

    assert eventually(fn -> assigns(a).editor_form["title"] == "Doc 7" end)
    agree!(a, c)
  end

  # task-38498e7e9fd76ede: B discards through its own page, so A's form is
  # reloaded by the discard's frame (`Desk.Discarded.reload/1`), not by a
  # Reload press. The header, the h1, the big title and the tab kept the dead
  # draft's title.
  test "B discards the draft it renamed through its own page: A names the published title", c do
    a = b_renamed_draft(c)
    b = open(c)

    press(b, "discard-draft")
    press(b, "confirm-discard")

    assert eventually(fn ->
             {:error, :not_found} == Content.get_document("drafts." <> c.id, c.type, @dataset)
           end)

    assert eventually(fn -> assigns(a).editor_form["title"] == "Doc 7" end)
    agree!(a, c)
  end

  test "publish after B renamed the draft names the published title", c do
    a = b_renamed_draft(c)
    press(a, "publish")

    assert eventually(fn ->
             {:error, :not_found} == Content.get_document("drafts." <> c.id, c.type, @dataset)
           end)

    agree!(a, c)
  end

  test "unpublish after B renamed the draft names the draft's title", c do
    a = b_renamed_draft(c)
    press(a, "unpublish")
    press(a, "confirm-unpublish")
    assert eventually(fn -> match?({:error, _}, Content.get_document(c.id, c.type, @dataset)) end)
    agree!(a, c)
  end

  test "moving to another document after B's rename names that document", c do
    other = c.id <> "-other"

    {:ok, _} =
      Content.create_document(c.type, %{"doc_id" => other, "title" => "Other"}, @dataset)

    a = open(c)
    b = open(c)
    posts(b, "title", "Doc 7 B1")
    assert eventually(fn -> header(a) == "Doc 7 B1" end)

    render_patch(a, String.replace(c.path, ";" <> c.id, ";" <> other))
    agree!(a, %{c | id: other})
    assert header(a) == "Other"
  end
end
