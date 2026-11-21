defmodule BarkparkWeb.Studio.DeskPickSettlesConflictTest do
  @moduledoc """
  task-a81b3c8c40eaf659: a `select-ref` pick saves through `{:autosave_form, …}`
  (`Refs.select_ref/2`, `Lifecycle.autosave_form/2`), and that save settles
  the buffer as a typed save does (`Fields.settle_dirty/2`). So a pick that
  lands while another user's save conflicts with edits not saved here ends
  the conflict: the banner goes, and the form is no longer dirty. TanStack's
  edit after a clash overrules theirs the same way (edits.ts `write`, the door
  every field write passes: "typing on after a clash: theirs is overruled, by
  the editor"). Today's desk picker writes a hidden input and saves as typed;
  this is the path the `select-ref`/`select-media` events still take.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"
  @pane "section[data-pane-editing]"
  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    person = "pick_person_#{n}"
    type = "pick_post_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => person,
          "title" => "People",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Name", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Pick posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [person]}
          ]
        },
        @dataset
      )

    author = "pick-author-#{n}"
    {:ok, _} = Content.create_document(person, %{"doc_id" => author, "title" => "Ada"}, @dataset)

    id = "pick-post-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => id, "title" => "Fixture", "content" => %{"excerpt" => "First"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "desk-pick-settles-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "desk-pick-settles", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    {:ok,
     conn: conn,
     type: type,
     id: id,
     author: author,
     path: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/_desk/#{type};#{id}"}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#{@pane} #editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  test "a reference pick that lands during a conflict ends it, as a typed save does", c do
    a = open(c)
    b = open(c)

    # A's excerpt edit is not saved yet.
    :sys.replace_state(a.pid, fn state ->
      socket = state.socket

      form = Map.put(socket.assigns.editor_form, "excerpt", "Mine, unsent")

      assigns =
        Map.merge(socket.assigns, %{
          editor_dirty: true,
          editor_unsaved_keys: MapSet.new(["excerpt"]),
          editor_form: form
        })

      %{state | socket: %{socket | assigns: assigns}}
    end)

    b
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc", "title"],
      "doc" => %{"title" => "From B", "excerpt" => "First"}
    })

    assert eventually(fn -> has_element?(a, @banner) end)
    assert assigns(a).doc_conflict == true

    # A picks the author.
    render_hook(a, "select-ref", %{
      PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.id),
      "field" => "author",
      "id" => c.author
    })

    assert eventually(fn -> assigns(a).save_status == "Saved" end)

    assert assigns(a).doc_conflict == false
    assert assigns(a).editor_dirty == false
    refute has_element?(a, @banner)
  end

  test "control: a reference pick with nothing in conflict saves and leaves the form clean", c do
    a = open(c)

    render_hook(a, "select-ref", %{
      PostIdentity.key() => PostIdentity.value(@dataset, c.type, c.id),
      "field" => "author",
      "id" => c.author
    })

    assert eventually(fn -> assigns(a).save_status == "Saved" end)
    assert assigns(a).editor_dirty == false
    refute has_element?(a, @banner)
  end
end
