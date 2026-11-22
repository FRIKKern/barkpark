defmodule BarkparkWeb.Studio.RemoteSaveSetBackTest do
  @moduledoc """
  task-1f6d4ed8c24a821b: A saves a choice, B saves another over it, and A
  picks its first one again. The desk read A's post against A's own last
  save, saw the value it already held, and said "Saved" without writing:
  B's choice stayed. A's pick is a change from what the form shows, so it
  is saved, as TanStack sends every field it changed. The old Studio got
  this right from its pane rebuild; both surfaces read the remote save
  through `Lifecycle.doc_updated/2`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"
  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "set_back_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Set back posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "stage",
              "title" => "Stage",
              "type" => "select",
              "options" => [
                %{"value" => "draft", "title" => "Draft"},
                %{"value" => "review", "title" => "Review"},
                %{"value" => "done", "title" => "Done"}
              ]
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    id = "set-back-post-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Fixture",
          "content" => %{"stage" => "draft", "notes" => "n"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "set-back-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "set-back", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, c.paths[surface])
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # A post of `key` as the page sends it: the whole form, `key` changed.
  defp picks(view, key, value) do
    form = Map.take(assigns(view).editor_form, ~w(title stage notes))

    view
    |> element("#editor-form")
    |> render_change(%{"_target" => ["doc", key], "doc" => Map.put(form, key, value)})
  end

  defp stored(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content
  end

  defp title(c) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.title
  end

  # A holds `edits` that did not reach the store (a save that did not land).
  defp unsaved!(view, edits) do
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket

      assigns =
        Map.merge(socket.assigns, %{
          editor_dirty: true,
          editor_unsaved_keys: MapSet.new(Map.keys(edits)),
          editor_form: Map.merge(socket.assigns.editor_form, edits)
        })

      %{state | socket: %{socket | assigns: assigns}}
    end)
  end

  # A saved "review", then B saved "done" over it and A's form shows it.
  defp b_over_a(c, surface) do
    a = open(c, surface)
    b = open(c, surface)
    picks(a, "stage", "review")
    assert eventually(fn -> stored(c)["stage"] == "review" end)
    picks(b, "stage", "done")
    assert eventually(fn -> assigns(a).editor_form["stage"] == "done" end)
    {a, b}
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: A picks its first choice again after B's: it is saved", c do
      {a, _b} = b_over_a(c, @surface)

      picks(a, "stage", "review")

      assert eventually(fn -> stored(c)["stage"] == "review" end)
      assert assigns(a).save_status == "Saved"
    end

    test "#{surface}: the same while A holds another field unsaved", c do
      a = open(c, @surface)
      b = open(c, @surface)
      picks(a, "stage", "review")
      assert eventually(fn -> stored(c)["stage"] == "review" end)
      unsaved!(a, %{"notes" => "n, mine"})
      picks(b, "stage", "done")
      assert eventually(fn -> assigns(a).editor_form["stage"] == "done" end)
      refute has_element?(a, @banner)

      picks(a, "stage", "review")

      assert eventually(fn -> stored(c)["stage"] == "review" end)
    end

    # A conflict that keeps A's whole buffer does not draw B's save: A's
    # next save does not write A's old choice back over B's.
    test "#{surface}: control: a whole-buffer conflict keeps B's choice", c do
      a = open(c, @surface)
      b = open(c, @surface)
      picks(a, "stage", "review")
      assert eventually(fn -> stored(c)["stage"] == "review" end)
      unsaved!(a, %{})
      picks(b, "stage", "done")
      assert eventually(fn -> assigns(a).doc_conflict == true end)
      assert assigns(a).editor_form["stage"] == "review"

      picks(a, "title", "Fixture, A")

      assert eventually(fn -> stored(c)["notes"] == "n" and title(c) == "Fixture, A" end)
      assert stored(c)["stage"] == "done"
    end
  end
end
