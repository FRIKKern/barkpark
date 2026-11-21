defmodule BarkparkWeb.Studio.StudioRestoreFenceTest do
  @moduledoc """
  task-5b74471e6a2d6de8: a restore from the Studio's own history names the
  document state the page showed, so it is refused when the document has
  moved on and writes nothing, the fence the history API has
  (task-e89ff0279fb83fc6).

  Every Restore sent only the revision id. A press that reached the server
  after someone else had written the document (the page not yet redrawn, a
  slow link) wrote the old revision over the newer words. Now each button
  carries the state it was drawn against: the history dialog and the
  revision view's Revert carry `if_rev`, the open document's rev
  (`editor_doc`), the deleted document's "Restore most recent revision"
  carries `if_absent`.

  `editor_doc` follows someone else's save while the form is clean: the
  save's document-list frame rebuilds the form and `editor_doc` from the
  store (`Lifecycle.document_changed/2`). While a field is dirty it stays
  put, so a restore is refused.

  A late press is played as the browser sends it: the button's values are
  read from the page, someone else writes, then the event goes with the
  values read before. The other person is this test process writing through
  `Barkpark.Content`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.{PostIdentity, RefusedSave}

  @dataset "production"
  @history ",changesInspectorTab=history,inspect=sanity%2Fstructure%2Fhistory"
  @moved "The document changed since you loaded it"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "rfence_#{n}"
    id = "rfence-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Fence #{n}",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Words A"}, @dataset)
    write(type, id, "Words B")

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "rfence-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "rfence", @dataset, ~w(read write admin), ws_id)
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     studio: "#{base}/#{type}/#{id}",
     desk: "#{base}/_desk/#{type};#{id}"}
  end

  # Someone else saves the draft.
  defp write(type, id, title) do
    {:ok, doc} =
      Content.upsert_document(
        type,
        %{"doc_id" => Content.draft_id(id), "title" => title},
        @dataset
      )

    doc
  end

  defp open(c, url) do
    {:ok, view, _html} = live(c.conn, url)
    render_async(view, 5_000)
    view
  end

  defp current(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc
  end

  defp revisions(c), do: c.id |> Content.list_revisions(c.type, @dataset, limit: 200) |> length()

  defp revision(c, title) do
    c.id
    |> Content.list_revisions(c.type, @dataset, limit: 200)
    |> Enum.find(&(&1.title == title and &1.action != "delete"))
    |> Map.fetch!(:id)
    |> to_string()
  end

  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash

  defp shown_rev(view), do: socket_assigns(view).editor_doc.rev
  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The `phx-value-*` a button carries, as the browser sends them.
  defp values(view, selector) do
    [el] = view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()

    for key <- ~w(id if_rev if_absent),
        [value] <- [LazyHTML.attribute(el, "phx-value-#{key}")],
        into: %{},
        do: {key, value}
  end

  # The history dialog's Restore of the revision titled `title`.
  defp dialog_values(view, c, title) do
    render_click(view, "show-history", %{})
    values(view, ~s(#history-list button[phx-value-id="#{revision(c, title)}"]))
  end

  # The value the revision view's Confirm pushes (`JS.push`).
  defp confirm_values(view) do
    [el] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("[data-pane-editing] [data-desk-revert-confirm]")
      |> Enum.to_list()

    [js] = LazyHTML.attribute(el, "phx-click")

    js
    |> Jason.decode!()
    |> Enum.find_value(fn
      ["push", %{"event" => "restore-revision", "value" => value}] -> value
      _ -> nil
    end)
  end

  defp press(view, params, marks \\ nil),
    do: EditorPost.press(view, "restore-revision", params, marks)

  # The open document's mark, as the desk's revision view carries it.
  defp own_mark(c), do: %{PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.id)}

  # The frames a save sends reach this process and not the page: the page
  # leaves the document topics and the document-list topics (whose frame
  # rebuilds its form from the store); this process joins them, as in
  # `StaleDocFrameTest`.
  defp hold_frames(view) do
    render(view)

    topics =
      Barkpark.PubSub
      |> Registry.keys(view.pid)
      |> Enum.filter(&String.starts_with?(&1, "doc"))

    assert Enum.any?(topics, &String.starts_with?(&1, "doc:")),
           "fixture: the page joined no document topic"

    :sys.replace_state(view.pid, fn state ->
      Enum.each(topics, &Phoenix.PubSub.unsubscribe(Barkpark.PubSub, &1))
      state
    end)

    Enum.each(topics, &Phoenix.PubSub.subscribe(Barkpark.PubSub, &1))
  end

  defp held_frame do
    receive do
      {:doc_updated, _msg} = frame -> frame
    after
      2_000 -> flunk("no frame was sent")
    end
  end

  describe "the deleted document's Restore most recent revision" do
    test "pressed after the document was written again: refused, the newer words stay", c do
      view = open(c, c.desk)
      {:ok, _} = Content.delete_document(c.id, c.type, @dataset)
      send(view.pid, {:document_changed, %{type: c.type, doc_id: c.id, mutation: "delete"}})
      send(view.pid, :desk_refresh)

      button = "[data-pane-editing] [data-desk-edit-gone] button[data-desk-restore-latest]"
      assert has_element?(view, button), "fixture: the gone document offers its restore"
      pressed = values(view, button)
      mark = EditorPost.mark(view)

      # Someone else restores it and writes over it before the press arrives.
      {:ok, _} = Content.restore_revision(pressed["id"], c.type, @dataset, if_absent: true)
      after_write = write(c.type, c.id, "Words C")
      count = revisions(c)

      press(view, pressed, mark)

      assert current(c).title == "Words C",
             "the late restore wrote the old revision over the newer words"

      assert current(c).rev == after_write.rev
      assert revisions(c) == count, "a refused restore wrote a revision"
      assert flash(view)["error"] =~ @moved
    end

    test "pressed while the document is still gone: restores", c do
      view = open(c, c.desk)
      {:ok, _} = Content.delete_document(c.id, c.type, @dataset)
      send(view.pid, {:document_changed, %{type: c.type, doc_id: c.id, mutation: "delete"}})
      send(view.pid, :desk_refresh)

      button = "[data-pane-editing] [data-desk-edit-gone] button[data-desk-restore-latest]"
      assert has_element?(view, button)
      assert values(view, button)["if_absent"] == "true"

      EditorPost.press_on(view, element(view, button))
      assert current(c).title == "Words B"
    end
  end

  describe "the history dialog's Restore" do
    test "pressed after someone else saved: refused, then the redrawn button restores", c do
      view = open(c, c.studio)
      pressed = dialog_values(view, c, "Words A")
      assert pressed["if_rev"] == current(c).rev

      after_write = write(c.type, c.id, "Words C")
      count = revisions(c)
      press(view, pressed)

      assert current(c).rev == after_write.rev, "the late restore wrote over the newer words"
      assert revisions(c) == count
      assert flash(view)["error"] =~ @moved

      # The page reads the document again; a press made against it restores.
      assert socket_assigns(view).editor_form["title"] == "Words C"
      press(view, dialog_values(view, c, "Words A"))
      assert current(c).title == "Words A"
    end

    # A reload drops a refused-save marker (`RefusedSave`); the read again after
    # a refusal is one. The marker here holds the newer words, which the form
    # shows after the reload, so a marker left behind would read as live.
    test "a refused press drops a refused-save marker from before", c do
      view = open(c, c.studio)
      pressed = dialog_values(view, c, "Words A")
      write(c.type, c.id, "Words C")
      render(view)

      :sys.replace_state(view.pid, fn state ->
        s = state.socket
        key = {c.type, c.id}
        marker = {key, %{"title" => {"Words C", "Refused for the test"}}}
        %{state | socket: %{s | assigns: Map.put(s.assigns, :editor_refused_clears, marker)}}
      end)

      assert RefusedSave.clears(%{assigns: socket_assigns(view)}) == ["title"],
             "fixture: the marker reads as live"

      press(view, pressed)
      assert flash(view)["error"] =~ @moved

      assert RefusedSave.clears(%{assigns: socket_assigns(view)}) == [],
             "the refused press left the refused-save marker"
    end

    test "someone else's save the page showed: the button names it, and restores", c do
      view = open(c, c.studio)
      after_write = write(c.type, c.id, "Words C")
      render(view)

      assert socket_assigns(view).editor_form["title"] == "Words C",
             "fixture: the page put the other save in the form"

      assert shown_rev(view) == after_write.rev
      press(view, dialog_values(view, c, "Words A"))
      assert current(c).title == "Words A", "a restore against the words on screen was refused"
    end

    test "someone else's save held behind a dirty field: the button does not name it", c do
      view = open(c, c.studio)
      shown = current(c).rev

      # The page holds an unsaved title, as after a failed save.
      :sys.replace_state(view.pid, fn state ->
        s = state.socket

        assigns =
          Map.merge(s.assigns, %{
            editor_dirty: true,
            editor_unsaved_keys: MapSet.new(["title"]),
            editor_form: Map.put(s.assigns.editor_form, "title", "Words unsent")
          })

        %{state | socket: %{s | assigns: assigns}}
      end)

      after_write = write(c.type, c.id, "Words C")
      render(view)
      assert shown_rev(view) == shown, "a save the page did not show moved the rev it names"

      press(view, dialog_values(view, c, "Words A"))
      assert current(c).rev == after_write.rev
      assert flash(view)["error"] =~ @moved
    end

    test "a write the page was never told of: refused (the safe side)", c do
      view = open(c, c.studio)
      hold_frames(view)
      after_write = write(c.type, c.id, "Words C")
      _frame = held_frame()

      press(view, dialog_values(view, c, "Words A"))
      assert current(c).rev == after_write.rev
      assert flash(view)["error"] =~ @moved
    end

    test "a press with no state, from a page drawn before the fence: restores as before", c do
      view = open(c, c.studio)
      id = revision(c, "Words A")
      write(c.type, c.id, "Words C")

      press(view, %{"id" => id})
      assert current(c).title == "Words A"
    end

    for {name, extra} <- [
          {"both states", %{"if_rev" => "x", "if_absent" => "true"}},
          {"an empty rev", %{"if_rev" => ""}},
          {"if_absent other than \"true\"", %{"if_absent" => "yes"}}
        ] do
      test "a press naming #{name}: refused, nothing written", c do
        view = open(c, c.studio)
        before = current(c).rev
        count = revisions(c)

        press(view, Map.merge(%{"id" => revision(c, "Words A")}, unquote(Macro.escape(extra))))

        assert current(c).rev == before
        assert revisions(c) == count
        assert flash(view)["error"] =~ "Failed to restore"
      end
    end
  end

  describe "the revision view's Revert to revision" do
    test "confirmed after someone else saved: refused, the newer words stay", c do
      view = open(c, c.desk <> @history <> ",rev=#{revision(c, "Words A")}")
      pressed = confirm_values(view)
      assert pressed["if_rev"] == current(c).rev

      after_write = write(c.type, c.id, "Words C")
      press(view, pressed, own_mark(c))

      assert current(c).rev == after_write.rev
      assert flash(view)["error"] =~ @moved
    end

    test "confirmed against the shown state: restores", c do
      view = open(c, c.desk <> @history <> ",rev=#{revision(c, "Words A")}")
      press(view, confirm_values(view), own_mark(c))
      assert current(c).title == "Words A"
    end
  end
end
