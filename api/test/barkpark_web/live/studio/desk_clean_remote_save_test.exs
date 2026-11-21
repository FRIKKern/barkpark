defmodule BarkparkWeb.Studio.DeskCleanRemoteSaveTest do
  @moduledoc """
  task-22f40460dbb71b27: another user's save over a desk form with nothing
  unsaved is taken into the form and says nothing, in the form status and in
  the footer: TanStack's footer keeps its "Edited …" (DocumentPane
  `DocFooter`) and has no words for it. Over unsaved edits it is a conflict
  and keeps its words.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @pane "section[data-pane-editing]"
  @words "Updated by another user"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "quiet_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Quiet posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "quiet-post-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Fixture", "content" => %{"excerpt" => "First"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-clean-remote-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-clean-remote", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn, path: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}"}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp text(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp b_saves(b) do
    b
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", "title"],
      "doc" => %{"title" => "From B", "excerpt" => "First"}
    })
  end

  test "another user's save over a clean form is taken in and says nothing", c do
    a = open(c)
    b = open(c)

    b_saves(b)

    assert eventually(fn -> assigns(a).editor_form["title"] == "From B" end)
    assert assigns(a).doc_conflict == false

    refute text(a, "#{@pane} .editor-actions .save-status") =~ @words
    refute text(a, "#{@pane} .dk-edit-footer .dk-footer-status") =~ @words
    assert text(a, "#{@pane} .dk-edit-footer .dk-footer-status") =~ "Edited"
    refute has_element?(a, ~s(#{@pane}[data-desk-save="#{@words}"]))
  end

  test "control: over unsaved edits it is a conflict and keeps its words", c do
    a = open(c)
    b = open(c)

    :sys.replace_state(a.pid, fn state ->
      socket = state.socket
      # The title, the field B's save rewrites: a conflict only where the
      # remote save rewrote this page's own field (task-65543203e7b71c80).
      form = Map.put(socket.assigns.editor_form, "title", "Mine, unsent")

      assigns =
        Map.merge(socket.assigns, %{
          editor_dirty: true,
          editor_unsaved_keys: MapSet.new(["title"]),
          editor_form: form
        })

      %{state | socket: %{socket | assigns: assigns}}
    end)

    b_saves(b)

    assert eventually(fn -> assigns(a).doc_conflict == true end)
    assert text(a, "#{@pane} .dk-edit-footer .dk-footer-status") =~ @words
  end
end
