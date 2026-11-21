defmodule BarkparkWeb.Studio.DeskStatusToneTest do
  @moduledoc """
  task-0ab0e8ca066765f0: "Updated by another user" over edits not saved
  here is TanStack's `refused` state, so `Desk.DocStyle` tones the form's
  status by the marks on the edit pane (`data-desk-save`,
  `data-desk-conflict`, set while `doc_conflict` is and the status still
  says so). Over a form with nothing unsaved the remote save is simply
  taken in, and the pane carries no conflict mark.

  "Read-only" is in the same rule (pinned in `DeskDocStyleTest`) but has no
  row here: the desk mounts for admins only, and an admin's write is never
  refused as read-only (a checked-out media asset's metadata included).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "section[data-pane-editing]"
  @status ".editor-actions .save-status"

  setup %{conn: conn} do
    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    ws_id = Tenancy.get_default_workspace().id
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk"
    {:ok, conn: conn, base: base, ws_id: ws_id, n: System.unique_integer([:positive])}
  end

  defp signed_in(conn, ws_id, perms) do
    raw = "desk-status-tone-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "desk-status-tone", @dataset, perms, ws_id)
    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp status(view), do: view |> element("#{@pane} #{@status}") |> render() |> strip()
  defp strip(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()

  describe "another user's save" do
    setup c do
      type = "tone_post_#{c.n}"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "Tone posts",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"}
            ]
          },
          @dataset
        )

      id = "tone-post-#{c.n}"

      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => id, "title" => "Fixture", "content" => %{"excerpt" => "First"}},
          @dataset
        )

      conn = signed_in(c.conn, c.ws_id, ~w(read write admin))
      {:ok, path: "#{c.base}/#{type};#{id}", conn: conn}
    end

    defp save_from(view, title) do
      view
      |> element("#editor-form")
      |> render_change(%{
        "_target" => ["doc", "title"],
        "doc" => %{"title" => title, "excerpt" => "First"}
      })
    end

    test "over edits not saved here, the pane carries the conflict mark", c do
      a = open(c.conn, c.path)
      b = open(c.conn, c.path)

      # A's title edit is not saved yet.
      :sys.replace_state(a.pid, fn state ->
        socket = state.socket

        # The title, the field B's save rewrites: a conflict only where the
        # remote save rewrote this page's own field (task-65543203e7b71c80).
        assigns =
          Map.merge(socket.assigns, %{
            editor_dirty: true,
            editor_unsaved_keys: MapSet.new(["title"]),
            editor_form: Map.put(socket.assigns.editor_form, "title", "Mine, unsent")
          })

        %{state | socket: %{socket | assigns: assigns}}
      end)

      save_from(b, "From B")

      assert eventually(fn ->
               has_element?(
                 a,
                 ~s(#{@pane}[data-desk-save="Updated by another user"][data-desk-conflict] #{@status})
               )
             end)

      assert status(a) == "Updated by another user"

      # The footer's words, where its caution rule reaches them
      # (task-d64e58f43f48de16).
      footer =
        ~s(#{@pane}[data-desk-save="Updated by another user"][data-desk-conflict] .dk-edit-footer button.dk-footer-status .save-state)

      assert has_element?(a, footer, "Updated by another user")
    end

    # #28139 review: a save through `{:autosave_form, …}` (a reference or an
    # image pick) says "Saved" but leaves `doc_conflict` set; the mark follows
    # the words, so "Saved" is not drawn as a refusal.
    test "a pick's save during a conflict says Saved, with no conflict mark", c do
      a = open(c.conn, c.path)
      b = open(c.conn, c.path)

      :sys.replace_state(a.pid, fn state ->
        socket = state.socket

        # The title, the field B's save rewrites: a conflict only where the
        # remote save rewrote this page's own field (task-65543203e7b71c80).
        assigns =
          Map.merge(socket.assigns, %{
            editor_dirty: true,
            editor_unsaved_keys: MapSet.new(["title"]),
            editor_form: Map.put(socket.assigns.editor_form, "title", "Mine, unsent")
          })

        %{state | socket: %{socket | assigns: assigns}}
      end)

      save_from(b, "From B")
      assert eventually(fn -> has_element?(a, "#{@pane}[data-desk-conflict]") end)

      send(a.pid, {:autosave_form, %{"title" => "From B", "excerpt" => "Mine"}})

      assert eventually(fn -> has_element?(a, ~s(#{@pane}[data-desk-save="Saved"])) end)
      assert :sys.get_state(a.pid).socket.assigns.doc_conflict == true
      refute has_element?(a, "#{@pane}[data-desk-conflict]")
      assert status(a) == "Saved"
    end

    test "over a form with nothing unsaved, the save is taken in with no conflict mark", c do
      a = open(c.conn, c.path)
      b = open(c.conn, c.path)

      save_from(b, "From B")

      assert eventually(fn ->
               has_element?(a, ~s(#{@pane}[data-desk-save="Updated by another user"]))
             end)

      refute has_element?(a, "#{@pane}[data-desk-conflict]")
    end
  end
end
