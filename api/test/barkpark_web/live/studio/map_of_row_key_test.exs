defmodule BarkparkWeb.Studio.MapOfRowKeyTest do
  @moduledoc """
  task-12ff178d188b04b4: an arrayOf whose `of` is a single map composite
  drew no `_key` input per row (`ArrayField` `composite_row_body/5`), so a
  post named its rows by index only. #29036's fold goes by a row's posted
  `_key`; with none it went by index, and a post typed before B took a row
  out or moved one wrote A's words into the row now at that index.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)
    type = c.type <> "-map"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Map rows",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{
              "name" => "items",
              "title" => "Items",
              "type" => "arrayOf",
              "of" => %{
                "type" => "composite",
                "name" => "item",
                "title" => "Item",
                "fields" => [%{"name" => "name", "title" => "Name", "type" => "string"}]
              }
            }
          ]
        },
        "production"
      )

    id = c.id <> "-map"

    {:ok, _} =
      Content.create_document(
        type,
        %{
          "doc_id" => id,
          "title" => "T0",
          "content" => %{"items" => [item("r1", "alpha"), item("r2", "beta")]}
        },
        "production"
      )

    Map.merge(c, %{type: type, id: id})
  end

  defp item(key, name), do: %{"_key" => key, "name" => name}

  defp open_map(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp put_items(c, items) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "items", items)
        },
        "production"
      )
  end

  # The rows' inputs as the page draws them, by name.
  defp drawn(view) do
    html =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(input[name^="doc[items]"]))

    Enum.zip(LazyHTML.attribute(html, "name"), LazyHTML.attribute(html, "value")) |> Map.new()
  end

  # A post sent before the page took B's change: the fields it drew, with A's edit.
  defp in_flight(view, how, target, fields) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(view.pid).socket.assigns

    params =
      fields
      |> Map.merge(%{"doc[title]" => "T0"})
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => BarkparkWeb.Studio.StudioLive.PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => [target]
      })

    render_hook(view, if(how == :auto, do: "autosave", else: "save"), params)
  end

  defp names(c), do: Map.new(stored(c)["items"], &{&1["_key"], &1["name"]})

  for surface <- [:desk, :studio] do
    test "#{surface}: each map row draws its _key", c do
      fields = c |> open_map(unquote(surface)) |> drawn()
      # On main only doc[items][i].name was drawn.
      assert fields["doc[items][0]._key"] == "r1"
      assert fields["doc[items][1]._key"] == "r2"
    end

    for how <- [:auto, :save] do
      test "#{surface} #{how}: B deletes the row A types in: never written into the next row",
           c do
        a = open_map(c, unquote(surface))
        fields = drawn(a) |> Map.put("doc[items][0].name", "alpha A")
        put_items(c, [item("r2", "beta")])
        assert eventually(fn -> length(form(a)["items"]) == 1 end)

        in_flight(a, unquote(how), "doc[items][0].name", fields)

        # On main: r2 became "alpha A", by index.
        assert names(c) == %{"r2" => "beta"}
      end

      test "#{surface} #{how}: B swaps the rows while A types in r1: A's words stay in r1", c do
        a = open_map(c, unquote(surface))
        fields = drawn(a) |> Map.put("doc[items][0].name", "alpha A")
        put_items(c, [item("r2", "beta"), item("r1", "alpha")])
        assert eventually(fn -> Enum.map(form(a)["items"], & &1["_key"]) == ["r2", "r1"] end)

        in_flight(a, unquote(how), "doc[items][0].name", fields)

        assert names(c) == %{"r1" => "alpha A", "r2" => "beta"}
        assert Enum.map(stored(c)["items"], & &1["_key"]) == ["r2", "r1"]
      end
    end
  end
end
