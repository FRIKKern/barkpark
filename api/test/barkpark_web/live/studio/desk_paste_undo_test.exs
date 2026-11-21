defmodule BarkparkWeb.Studio.DeskPasteUndoTest do
  @moduledoc """
  task-f4c570d2a11cd7df (found reviewing #27970): in the desk, a Paste field
  or Paste document write was no step of the document's undo, for any field
  type. Mod+Z after a paste did nothing for it, or took back the edit before.

  A paste is now recorded as the TanStack Studio records every write
  (`edits.ts` `write`): one step per field it wrote. Free text is a text
  step, as typing is; any other value a whole-value step. Undo restores the
  value from before the paste, and redo puts the paste back. Paste document
  writes each field it fills as its own step, as TanStack's does (one
  `onEdit` per field).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"
  @form "[data-pane-editing] #editor-form"

  setup %{conn: conn} do
    type = "pu_book_#{System.unique_integer([:positive])}"
    kinds = %{"list" => [%{"title" => "A", "value" => "a"}, %{"title" => "B", "value" => "b"}]}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Paste undo",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "name", "title" => "Name", "type" => "string"},
            %{"name" => "other", "title" => "Other", "type" => "string"},
            %{"name" => "kind", "title" => "Kind", "type" => "string", "options" => kinds},
            %{"name" => "count", "title" => "Count", "type" => "number"},
            %{"name" => "count2", "title" => "Count 2", "type" => "number"},
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "paste-undo-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "paste-undo", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  defp doc!(c, content) do
    id = "pu-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => content},
        @dataset
      )

    id
  end

  defp desk(c, id) do
    {:ok, view, _html} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, @form)
    view
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  defp pressed(view, params),
    do: Map.merge(Map.take(EditorPost.marks(view), ["_bp_doc"]), params)

  defp copy_field(view, name) do
    render_hook(view, "desk-field-copy", %{"field" => name})
    assert_push_event(view, "desk:field-copied", %{json: json})
    json
  end

  defp paste_field(view, name, clip) do
    render_hook(view, "desk-field-paste", pressed(view, %{"field" => name, "clip" => clip}))
    Process.sleep(650)
  end

  defp type(view, name, value) do
    view
    |> form(@form, %{"doc" => %{name => value}})
    |> render_change(%{"_target" => ["doc", name]})

    # Past the undo's grouping of quick edits to one field.
    Process.sleep(650)
  end

  defp undo(view, redo \\ false) do
    render_hook(view, "desk-undo", pressed(view, %{"redo" => redo}))
    render(view)
  end

  test "Paste field over typed text: Mod+Z brings the typed text back, redo the paste", c do
    id = doc!(c, %{"name" => "n0", "other" => "pasted", "notes" => "x"})
    view = desk(c, id)

    type(view, "name", "typed")
    paste_field(view, "name", copy_field(view, "other"))
    assert stored(c, id)["name"] == "pasted"

    undo(view)
    assert stored(c, id)["name"] == "typed"
    undo(view, true)
    assert stored(c, id)["name"] == "pasted"

    # The typed edit before it is still a step of its own.
    undo(view)
    undo(view)
    assert stored(c, id)["name"] == "n0"
    assert stored(c, id)["notes"] == "x"
  end

  test "Paste field into a number and an options string: each is one step", c do
    id = doc!(c, %{"count" => 1, "count2" => 5, "kind" => "a"})
    view = desk(c, id)

    paste_field(view, "count", copy_field(view, "count2"))
    assert stored(c, id)["count"] == 5

    source = doc!(c, %{"kind" => "b"})
    clip = copy_field(desk(c, source), "kind")
    paste_field(view, "kind", clip)
    assert stored(c, id)["kind"] == "b"

    undo(view)
    assert stored(c, id)["kind"] == "a"
    assert stored(c, id)["count"] == 5
    undo(view)
    assert stored(c, id)["count"] == 1
  end

  test "Paste document: each field it wrote undoes, back to the document before it", c do
    from = doc!(c, %{"name" => "N2", "kind" => "b", "count" => 9})
    source = desk(c, from)
    render_hook(source, "desk-doc-copy", %{})
    assert_push_event(source, "desk:doc-copied", %{json: json})

    to = doc!(c, %{"name" => "N1", "kind" => "a", "count" => 1, "notes" => "keep"})
    view = desk(c, to)
    before = stored(c, to)
    render_hook(view, "desk-doc-paste", pressed(view, %{"clip" => json}))
    assert %{"name" => "N2", "kind" => "b", "count" => 9} = stored(c, to)

    # The last field written goes first (schema order: title, name, kind, count).
    undo(view)
    assert stored(c, to)["count"] == 1
    assert stored(c, to)["kind"] == "b"

    # The title is the same in both: written over itself, it is no step.
    for _ <- 1..2, do: undo(view)

    assert Map.take(stored(c, to), ~w(name kind count notes)) ==
             Map.take(before, ~w(name kind count notes))

    undo(view, true)
    assert stored(c, to)["name"] == "N2"
    assert stored(c, to)["kind"] == "a"
  end
end
