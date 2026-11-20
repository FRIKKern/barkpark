defmodule BarkparkWeb.Studio.NestedSelectTicksTest do
  @moduledoc """
  task-9c069dfef8b99cb3 (found in the review of #27958): ticking a checkbox
  of an `arrayOf` select inside an object or an array row broke the
  document, in both Studios.

  The checkboxes were named `doc[obj].arr[]`. `Plug.Conn.Query.decode/1`
  reads that as the key `"obj].arr["` holding the last ticked value only, so
  the save stored one string (`"b"`) for the list, and for every other such
  list in the post. The page then raised drawing a string as a list, on that
  post and on every later open of the document.

  Ticks inside an object or a row now save as a list, the other fields of
  the object or row stay, the page stays up, and a document that already
  holds such a string opens.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @dataset "production"

  defp sel, do: %{"name" => "s", "type" => "select", "options" => ["a", "b"]}

  defp holder(name),
    do: [
      %{"name" => "label", "title" => "Label", "type" => "string"},
      %{"name" => name, "title" => "Ticks", "type" => "arrayOf", "of" => sel()}
    ]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "nsel_#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Nested select #{n}",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "top", "title" => "Top", "type" => "arrayOf", "of" => sel()},
            %{
              "name" => "obj",
              "title" => "Obj",
              "type" => "composite",
              "fields" => holder("arr")
            },
            %{
              "name" => "rows",
              "title" => "Rows",
              "type" => "arrayOf",
              "of" => %{"type" => "composite", "fields" => holder("arr")}
            },
            # An object inside an array row.
            %{
              "name" => "deep",
              "title" => "Deep",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "fields" => [
                  %{"name" => "note", "title" => "Note", "type" => "string"},
                  %{
                    "name" => "inner",
                    "title" => "Inner",
                    "type" => "composite",
                    "fields" => holder("arr")
                  }
                ]
              }
            },
            %{"name" => "notes", "title" => "Notes", "type" => "string"}
          ]
        },
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "nsel-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "nsel", @dataset, ~w(read write admin), ws_id)

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{"api_token" => raw}),
     root: "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio",
     type: type}
  end

  defp doc!(c, content) do
    id = "nsel-#{System.unique_integer([:positive])}"

    base = %{
      "top" => ["a"],
      "obj" => %{"label" => "l", "arr" => ["b"]},
      "rows" => [%{"_key" => "r1", "label" => "r", "arr" => ["a"]}],
      "deep" => [%{"_key" => "d1", "note" => "d", "inner" => %{"label" => "i", "arr" => ["b"]}}],
      "notes" => "n0"
    }

    {:ok, _} =
      Content.create_document(
        c.type,
        %{"doc_id" => id, "title" => "Book", "content" => Map.merge(base, content)},
        @dataset
      )

    id
  end

  defp open(c, :desk, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/_desk/#{c.type};#{id}")
    render_async(view, 5_000)
    assert has_element?(view, "[data-pane-editing] #editor-form")
    {view, "[data-pane-editing] #editor-form"}
  end

  defp open(c, :studio, id) do
    {:ok, view, _} = live(c.conn, "#{c.root}/#{c.type}/#{id}")
    assert has_element?(view, "#editor-form")
    {view, "#editor-form"}
  end

  defp stored(c, id) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, id, @dataset)
    doc.content || %{}
  end

  # The name the page gives the checkboxes of the list under `holder`.
  defp tick_name(view, form, holder) do
    html = view |> element(form) |> render()

    case Regex.run(~r/<input type="checkbox" name="(doc\[#{holder}[^"]*)"/, html) do
      [_, name] -> name
      _ -> flunk("no checkbox under #{holder}")
    end
  end

  # The browser's post of the list with `ticks` ticked, as LiveView sends
  # it: the form's inputs by name, decoded the way Plug decodes them.
  defp tick(view, form, holder, ticks) do
    name = tick_name(view, form, holder)
    hidden = [{name, ""} | Enum.map(ticks, &{name, &1})]
    data = hidden |> URI.encode_query() |> Plug.Conn.Query.decode()

    view
    |> form(form, data)
    |> render_change(%{"_target" => target(name)})
  end

  defp edit_notes(view, form, value) do
    view
    |> form(form, %{"doc" => %{"notes" => value}})
    |> render_change(%{"_target" => ["doc", "notes"]})
  end

  # LiveView's `_target`: the input name as a list of keys.
  defp target(name) do
    %{name => ""} |> URI.encode_query() |> Plug.Conn.Query.decode() |> keys([])
  end

  defp keys(%{} = map, acc) do
    case Map.to_list(map) do
      [{key, %{} = inner}] -> keys(inner, [key | acc])
      [{key, _leaf}] -> Enum.reverse([key | acc])
    end
  end

  @stored %{
    "top" => ["a"],
    "obj" => %{"label" => "l", "arr" => ["b"]},
    "rows" => [%{"_key" => "r1", "label" => "r", "arr" => ["a"]}],
    "deep" => [%{"_key" => "d1", "note" => "d", "inner" => %{"label" => "i", "arr" => ["b"]}}]
  }

  # Each list's place in the post and in the stored document.
  @shapes [
    {"a top-level list", "top", ["top"]},
    {"a list in an object", "obj", ["obj", "arr"]},
    {"a list in an array row", "rows", ["rows", 0, "arr"]},
    {"a list in an object in an array row", "deep", ["deep", 0, "inner", "arr"]}
  ]

  defp at(value, []), do: value
  defp at(list, [i | rest]) when is_list(list) and is_integer(i), do: at(Enum.at(list, i), rest)
  defp at(%{} = map, [k | rest]), do: at(Map.get(map, k), rest)

  defp put_at(_value, [], new), do: new

  defp put_at(list, [i | rest], new) when is_list(list),
    do: List.update_at(list, i, &put_at(&1, rest, new))

  defp put_at(%{} = map, [k | rest], new), do: Map.update!(map, k, &put_at(&1, rest, new))

  for surface <- [:desk, :studio], {label, holder, path} <- @shapes do
    @surface surface
    @holder holder
    @path path

    test "#{surface}: ticks in #{label} save as a list; nothing else changes", c do
      id = doc!(c, %{})
      {view, form} = open(c, @surface, id)

      tick(view, form, @holder, ["a", "b"])

      assert Map.take(stored(c, id), Map.keys(@stored)) == put_at(@stored, @path, ["a", "b"])
      assert stored(c, id)["notes"] == "n0"
      assert has_element?(view, form)

      # Every tick taken off.
      tick(view, form, @holder, [])

      assert at(stored(c, id), @path) in [[], nil]

      assert Map.take(stored(c, id), Map.keys(@stored) -- [hd(@path)]) ==
               Map.delete(@stored, hd(@path))
    end
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: a document that holds a string for such a list opens", c do
      id = doc!(c, %{"obj" => %{"label" => "l", "arr" => "b"}})
      {view, form} = open(c, @surface, id)

      assert has_element?(
               view,
               ~s(#{form} input[type="checkbox"][name^="doc[obj"][value="b"][checked])
             )

      # Opening writes nothing, and nor does an edit of another field.
      assert stored(c, id)["obj"]["arr"] == "b"
      edit_notes(view, form, "n1")
      assert stored(c, id)["notes"] == "n1"
      assert stored(c, id)["obj"] == %{"label" => "l", "arr" => "b"}
    end

    test "#{surface}: an edit of another field leaves every list as stored", c do
      id = doc!(c, %{})
      {view, form} = open(c, @surface, id)

      edit_notes(view, form, "n1")

      assert stored(c, id)["notes"] == "n1"
      assert Map.take(stored(c, id), Map.keys(@stored)) == @stored
      assert has_element?(view, form)
    end
  end
end
