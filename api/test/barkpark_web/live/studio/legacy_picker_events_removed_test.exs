defmodule BarkparkWeb.Studio.LegacyPickerEventsRemovedTest do
  @moduledoc """
  task-c42545346b93cbb0: the legacy picker modals and their events are gone.
  Reference and image fields are `<bp-reference-picker>` / `<bp-media-picker>`,
  which save through their hidden input as a typed `autosave`. The modals'
  `select-ref`, `clear-ref`, `select-media`, `clear-image` and `upload-image`
  (and `{:autosave_form, …}`, which they sent) had no control left on any
  page, yet a crafted one still saved, without settling the form
  (#28162 review). Now such an event, even carrying the open document's own
  mark, writes nothing on the desk or on the old Studio page, and the page
  stays up.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    person = "legacy_person_#{n}"
    type = "legacy_post_#{n}"

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
          "title" => "Legacy posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "author", "title" => "Author", "type" => "reference", "to" => [person]},
            %{"name" => "cover", "title" => "Cover", "type" => "image"}
          ]
        },
        @dataset
      )

    author = "legacy-author-#{n}"
    {:ok, _} = Content.create_document(person, %{"doc_id" => author, "title" => "Ada"}, @dataset)

    id = "legacy-post-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Fixture",
          "content" => %{"author" => author, "cover" => "/media/files/cover.png"}
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "legacy-picker-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "legacy-picker", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     author: author,
     paths: %{desk: "#{root}/_desk/#{type};#{id}", studio: "#{root}/#{type}/#{id}"}}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, c.paths[surface])
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  # What the store holds of the fields a pick would change, draft first.
  defp stored(c) do
    doc =
      case Content.get_document("drafts." <> c.id, c.type, @dataset) do
        {:ok, draft} -> draft
        _ -> elem(Content.get_document(c.id, c.type, @dataset), 1)
      end

    {doc.title, inspect(doc.content["author"]), doc.content["cover"]}
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: a crafted legacy pick, pressed with the page's own mark, saves nothing",
         c do
      view = open(c, @surface)
      before = stored(c)

      for {event, params} <- [
            {"select-ref", %{"field" => "author", "id" => "someone-else"}},
            {"clear-ref", %{"field" => "author"}},
            {"select-media", %{"field" => "cover", "url" => "/media/files/crafted.png"}},
            {"clear-image", %{"field" => "cover"}},
            {"upload-image", %{"field" => "cover"}}
          ] do
        EditorPost.press(view, event, params)
        render(view)
        assert stored(c) == before, "#{event} wrote"
      end

      send(view.pid, {:autosave_form, %{"title" => "Crafted", "author" => "someone-else"}})
      render(view)
      assert stored(c) == before, "{:autosave_form, …} wrote"

      assert Process.alive?(view.pid)
      assert has_element?(view, "#editor-form")
    end
  end
end
