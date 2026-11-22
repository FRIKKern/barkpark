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
end
