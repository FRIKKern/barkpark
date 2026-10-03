defmodule BarkparkWeb.Studio.V2WidgetsDocSwitchTest do
  @moduledoc """
  The doc-switch corruption fixed for top-level rich text, reference and
  image fields (task-eda246dcab63dc3f, #21229) also lived in the v2 field
  components: a rich `localizedText` language and a composite `image`
  subfield render inside `phx-update="ignore"` wrappers keyed only by field
  name, so a doc-to-doc patch kept the previous document's hidden input and
  the next autosave wrote it into the document now open. LiveViewTest
  applies `phx-update="ignore"` like the browser, so the hidden inputs read
  here are what the browser would post.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "talk",
          "title" => "Talk",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "abstract",
              "title" => "Abstract",
              "type" => "localizedText",
              "languages" => ["nob", "eng"],
              "format" => "rich"
            },
            %{
              "name" => "venue",
              "title" => "Venue",
              "type" => "composite",
              "fields" => [
                %{"name" => "name", "title" => "Name", "type" => "string"},
                %{"name" => "photo", "title" => "Photo", "type" => "image"}
              ]
            }
          ]
        },
        @dataset
      )

    for {id, word, photo} <- [
          {"t1", "first", "/media/one.png"},
          {"t2", "second", "/media/two.png"}
        ] do
      {:ok, _} =
        Content.create_document(
          "talk",
          %{
            "doc_id" => id,
            "title" => "Talk #{id}",
            "content" => %{
              "abstract" => %{"nob" => "<p>#{word} nob</p>", "eng" => "<p>#{word} eng</p>"},
              "venue" => %{"name" => "Hall #{id}", "photo" => photo}
            }
          },
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "talk", @dataset)
    end

    :ok
  end

  defp hidden_value(html, name) do
    case Regex.run(
           ~r{<input[^>]*type="hidden"[^>]*name="#{Regex.escape(name)}"[^>]*value="([^"]*)"},
           html
         ) do
      [_, value] -> value
      _ -> flunk("no hidden input named #{name} in the render")
    end
  end

  test "patching to another talk shows that talk's rich localized abstract", %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/talk/t1"))
    assert hidden_value(html, "doc[abstract].nob") =~ "first nob"

    html = render_patch(view, scoped_studio("/d/#{@dataset}/studio/talk/t2"))
    assert hidden_value(html, "doc[abstract].nob") =~ "second nob"
    assert hidden_value(html, "doc[abstract].eng") =~ "second eng"
  end

  test "patching to another talk shows that talk's composite image", %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/talk/t1"))
    assert hidden_value(html, "doc[venue].photo") =~ "one.png"

    html = render_patch(view, scoped_studio("/d/#{@dataset}/studio/talk/t2"))
    assert hidden_value(html, "doc[venue].photo") =~ "two.png"
  end
end
