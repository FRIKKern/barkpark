defmodule BarkparkWeb.Studio.DeskDocUndoGroupsTest do
  @moduledoc """
  task-c25c112913859b11, review round 2: the desk draws the chosen group
  tab's fields only. An undo of a field on another tab switches to a tab
  that draws it, so nothing changes where the user cannot see it, and the
  page is told the field so the focus goes there (`Desk.DocUndo`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "grp_post_#{n}"
    doc_id = "grp-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Group posts",
          "visibility" => "public",
          "groups" => [
            %{"name" => "main", "title" => "Main", "default" => true},
            %{"name" => "meta", "title" => "Meta"}
          ],
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string", "group" => "main"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text", "group" => "main"},
            %{"name" => "note", "title" => "Note", "type" => "text", "group" => "meta"},
            %{
              "name" => "folded",
              "title" => "Folded",
              "type" => "text",
              "group" => "meta",
              "fieldset" => "more"
            }
          ],
          "fieldsets" => [
            %{
              "name" => "more",
              "title" => "More",
              "options" => %{"collapsible" => true, "collapsed" => true}
            }
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => doc_id,
          "title" => "T",
          "content" => %{"excerpt" => "Short.", "note" => "N", "folded" => "F"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "grp-undo-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "grp-undo", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"
    {:ok, conn: conn, desk: "#{base}/_desk/#{type};#{doc_id}", type: type, doc_id: doc_id}
  end

  defp mark(c), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.doc_id)}

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    doc.content
  end

  defp type_in(view, key, value) do
    form = :sys.get_state(view.pid).socket.assigns.editor_form

    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", key],
      "doc" => Map.merge(Map.take(form, ["title", key]), %{key => value}),
      "_bp_seen" => Jason.encode!(%{"v" => 2})
    })
  end

  defp tab(view, group) do
    render_click(view, "select-group", %{"group" => group})
    render(view)
  end

  defp drawn?(view, key), do: has_element?(view, ~s(#editor-form [name="doc[#{key}]"]))

  defp undo(view, c) do
    render_hook(view, "desk-undo", Map.put(mark(c), "redo", false))
    render(view)
  end

  test "an undo of a field on a tab not shown switches to its tab, then changes it", c do
    {:ok, view, _} = live(c.conn, c.desk)
    render(view)
    assert drawn?(view, "excerpt")

    type_in(view, "excerpt", "Short. E1")
    assert stored(c)["excerpt"] == "Short. E1"

    tab(view, "meta")
    refute drawn?(view, "excerpt")
    assert drawn?(view, "note")

    undo(view, c)
    assert stored(c)["excerpt"] == "Short."
    assert drawn?(view, "excerpt"), "the excerpt's tab is shown, so the change is in sight"
    assert has_element?(view, ~s(#bp-group-tab-main[aria-selected="true"]))
    assert_push_event(view, "desk:undone", %{field: "doc[excerpt]", value: "Short."})
  end

  test "the other way round: a Meta field undone from the Main tab shows Meta", c do
    {:ok, view, _} = live(c.conn, c.desk)
    render(view)
    tab(view, "meta")
    type_in(view, "note", "N R1")
    assert stored(c)["note"] == "N R1"

    tab(view, "main")
    refute drawn?(view, "note")

    undo(view, c)
    assert stored(c)["note"] == "N"
    assert drawn?(view, "note")
    assert has_element?(view, ~s(#bp-group-tab-meta[aria-selected="true"]))
  end

  # Review round 3, path 1: the tab switched to draws the field's fieldset
  # folded (`options.collapsed`). The fold's state lives in the page, on its
  # title button (`Desk.Fieldsets`), so the server draws it folded; the page
  # opens it when told the field (`desk:undone`, bp-desk-undo.js, host test
  # __desk_undo "a field drawn in a fieldset that starts folded ...").
  test "a field in a fieldset that starts folded, undone from another tab: its tab, and the page told",
       c do
    {:ok, view, _} = live(c.conn, c.desk)
    render(view)
    tab(view, "meta")
    type_in(view, "folded", "F X")
    assert stored(c)["folded"] == "F X"

    tab(view, "main")
    refute drawn?(view, "folded")

    undo(view, c)
    assert stored(c)["folded"] == "F"
    assert has_element?(view, ~s(#bp-group-tab-meta[aria-selected="true"]))

    assert has_element?(
             view,
             ~s(fieldset[data-collapsible] > legend > .object-toggle[aria-expanded="false"])
           )

    assert has_element?(view, ~s(fieldset[data-collapsible] [name="doc[folded]"]))
    assert_push_event(view, "desk:undone", %{field: "doc[folded]", value: "F"})
  end

  test "a field on the tab shown leaves the tab where it is", c do
    {:ok, view, _} = live(c.conn, c.desk)
    render(view)
    tab(view, "meta")
    type_in(view, "note", "N R1")

    undo(view, c)
    assert stored(c)["note"] == "N"
    assert has_element?(view, ~s(#bp-group-tab-meta[aria-selected="true"]))
  end
end
