defmodule BarkparkWeb.Studio.DeskTagsOrCheckboxesTest do
  @moduledoc """
  task-5935f433650841be: tags or a checkbox list, by TanStack's rule and in
  its order (barkpark-studio `Fields.tsx`, `case 'arrayOf'`):

    1. an array of strings with `options.list` is a checkbox list, even with
       `options.layout: "tags"`;
    2. an array of strings or texts with `options.layout: "tags"` is tags.

  `of` must name its type, and `layout` is read from `options` only: an
  array with no `of`, or with `layout` beside `options`, is not tags.
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
    n = System.unique_integer([:positive])
    type = "tagorbox_#{n}"
    tags = %{"layout" => "tags"}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Tags or boxes",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "picks",
              "title" => "Picks",
              "type" => "arrayOf",
              "of" => %{"type" => "string"},
              "options" => Map.put(tags, "list", ["red", "green", "blue"])
            },
            %{
              "name" => "colours",
              "title" => "Colours",
              "type" => "arrayOf",
              "of" => %{"type" => "string"},
              "options" => %{"list" => [%{"value" => "red", "title" => "Red"}, "green"]}
            },
            %{
              "name" => "words",
              "title" => "Words",
              "type" => "arrayOf",
              "of" => %{"type" => "text"},
              "options" => Map.put(tags, "list", ["red"])
            },
            %{"name" => "loose", "title" => "Loose", "type" => "arrayOf", "options" => tags},
            %{
              "name" => "beside",
              "title" => "Beside",
              "type" => "arrayOf",
              "of" => %{"type" => "string"},
              "layout" => "tags"
            }
          ]
        },
        @dataset
      )

    id = "tagorbox-#{n}"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "Boxes",
          "content" => %{
            "picks" => ["green"],
            "colours" => ["red"],
            "words" => ["w"],
            "loose" => ["l"],
            "beside" => ["b"]
          }
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "tags-or-boxes-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "tags-or-boxes", @dataset, ~w(read write admin), ws_id)
    root = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     type: type,
     id: id,
     desk: "#{root}/_desk/#{type};#{id}",
     studio: "#{root}/#{type}/#{id}"}
  end

  defp open(c, surface) do
    {:ok, view, _html} = live(c.conn, Map.fetch!(c, surface))
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp eventually(fun), do: Enum.any?(1..200, fn _ -> fun.() or (Process.sleep(10) && false) end)

  defp stored(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.id, @dataset)
    doc.content
  end

  defp field(name), do: ~s(#editor-form [data-field-name="#{name}"])

  defp boxes(view, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(field(name) <> ~s( input[type="checkbox"]))
    |> Enum.map(fn box ->
      {LazyHTML.attribute(box, "value"), LazyHTML.attribute(box, "checked")}
    end)
    |> Enum.map(fn {[value], checked} -> {value, checked != []} end)
  end

  test "strings with options.list and the tags layout are a checkbox list, not tags", c do
    view = open(c, :desk)

    refute has_element?(view, field("picks") <> " .tags-box")
    assert boxes(view, "picks") == [{"red", false}, {"green", true}, {"blue", false}]
  end

  test "ticks save in option order; none ticked saves an empty list", c do
    view = open(c, :desk)

    EditorPost.change(view, %{
      "_target" => ["doc", "picks"],
      "doc" => %{"picks" => ["", "blue", "red"]}
    })

    assert eventually(fn -> stored(c)["picks"] == ["blue", "red"] end)

    EditorPost.change(view, %{"_target" => ["doc", "picks"], "doc" => %{"picks" => [""]}})
    assert eventually(fn -> stored(c)["picks"] in [[], nil] end)
  end

  test "strings with options.list are a checkbox list on both surfaces, titles read", c do
    for surface <- [:desk, :studio] do
      view = open(c, surface)
      assert boxes(view, "colours") == [{"red", true}, {"green", false}]
      assert render(element(view, field("colours"))) =~ "Red"
    end
  end

  test "texts with options.list and the tags layout stay tags, as TanStack's", c do
    view = open(c, :desk)
    assert has_element?(view, field("words") <> " .tags-box")
  end

  test "no `of`, or `layout` beside `options`, is not tags", c do
    view = open(c, :desk)
    refute has_element?(view, field("loose") <> " .tags-box")
    refute has_element?(view, field("beside") <> " .tags-box")
    assert has_element?(view, field("picks"))
  end

  test "a tags press at any of them stores nothing", c do
    view = open(c, :desk)
    before = stored(c)

    for name <- ~w(picks colours loose beside) do
      EditorPost.press(view, "array_op", %{
        "action" => "add_tag",
        "field" => name,
        "path" => "doc[#{name}]",
        "index" => "0",
        "value" => "bare"
      })
    end

    render(view)
    assert stored(c) == before
  end
end
