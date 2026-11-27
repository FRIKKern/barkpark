defmodule BarkparkWeb.Studio.RowPostByKeyTest do
  @moduledoc """
  task-406358090c6137e7: a post sent before the page took a change to an
  array's rows names its rows by the old indexes. `Fields.fold_dot_paths/2`
  wrote each dotted leaf by index into the editor's own rows, so after B took
  row r1 out (r2 moved up to 0), A's in-flight post wrote r1's `_key` and
  A's words over r2, and its `rows[1]` had no row to land in: B's delete was
  undone and r2 was gone. A row's leaves now go to the row of its posted
  `_key`; a row the editor no longer holds is dropped.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  setup %{conn: conn}, do: setup_doc(conn)

  defp put_rows(c, rows) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = put_in(doc.content, ["meta", "rows"], rows)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp rt_row(key, text),
    do: %{"_type" => "row", "_key" => key, "rt" => [block("w" <> key, text)]}

  defp by_key(rows, field), do: Map.new(rows, &{&1["_key"], &1[field]})

  # A post sent before the page took a patch: exactly these fields, as a
  # browser encodes them (`render_change` would merge the patched inputs).
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

  defp rt_fields(rows) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {{key, html}, i} ->
      p = "doc[meta].rows[#{i}]"
      [{p <> "._type", "row"}, {p <> "._key", key}, {p <> ".rt", html}]
    end)
    |> Map.new()
    |> Map.put("doc[meta].label", "l0")
  end

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    @tag timeout: 120_000
    test "#{surface} #{how}: B deletes the row A types in: B's delete and the next row kept",
         c do
      c = Map.put(c, :surface, unquote(surface))
      put_rows(c, [rt_row("r1", "one two"), rt_row("r2", "three four")])
      a = open(c)
      put_rows(c, [rt_row("r2", "three four")])
      assert eventually(fn -> length(form(a)["meta"]["rows"]) == 1 end)

      fields = rt_fields([{"r1", "<p>ONE two</p>"}, {"r2", "<p>three four</p>"}])
      in_flight(a, unquote(how), "doc[meta].rows[0].rt", fields)

      rows = stored(c)["meta"]["rows"]
      assert Enum.map(rows, & &1["_key"]) == ["r2"], "B's delete undone: #{inspect(rows)}"
      assert words(hd(rows)["rt"]) == ["three four"], "another row took A's words"
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: B swaps the rows: B's order kept, A's words in A's row", c do
      c = Map.put(c, :surface, unquote(surface))
      put_rows(c, [rt_row("r1", "one two"), rt_row("r2", "three four")])
      a = open(c)
      put_rows(c, [rt_row("r2", "three four"), rt_row("r1", "one two")])
      assert eventually(fn -> hd(form(a)["meta"]["rows"])["_key"] == "r2" end)

      fields = rt_fields([{"r1", "<p>ONE two</p>"}, {"r2", "<p>three four</p>"}])
      in_flight(a, unquote(how), "doc[meta].rows[0].rt", fields)

      rows = stored(c)["meta"]["rows"]
      assert Enum.map(rows, & &1["_key"]) == ["r2", "r1"], "B's move undone: #{inspect(rows)}"
      assert Enum.map(rows, &words(&1["rt"])) == [["three four"], ["ONE two"]]
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: control, rows unchanged: A's row post is written by index", c do
      c = Map.put(c, :surface, unquote(surface))
      put_rows(c, [rt_row("r1", "one two"), rt_row("r2", "three four")])
      a = open(c)

      fields = rt_fields([{"r1", "<p>ONE two</p>"}, {"r2", "<p>three four</p>"}])
      in_flight(a, unquote(how), "doc[meta].rows[0].rt", fields)

      rows = stored(c)["meta"]["rows"]
      assert Enum.map(rows, & &1["_key"]) == ["r1", "r2"]
      assert Enum.map(rows, &words(&1["rt"])) == [["ONE two"], ["three four"]]
    end
  end

  describe "a row of plain strings" do
    setup c do
      type = c.type <> "-str"

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => type,
            "title" => "String rows",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "items",
                "title" => "Items",
                "type" => "arrayOf",
                "of" => [
                  %{
                    "type" => "composite",
                    "name" => "item",
                    "title" => "Item",
                    "fields" => [%{"name" => "name", "title" => "Name", "type" => "string"}]
                  }
                ]
              }
            ]
          },
          "production"
        )

      id = c.id <> "-str"
      items = [item("r1", "alpha"), item("r2", "beta")]

      {:ok, _} =
        Content.create_document(
          type,
          %{"doc_id" => id, "title" => "T0", "content" => %{"items" => items}},
          "production"
        )

      {:ok, type: type, id: id}
    end

    defp item(key, name), do: %{"_type" => "item", "_key" => key, "name" => name}

    defp open_plain(c, surface) do
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

    for surface <- [:desk, :studio], how <- [:auto, :save] do
      @tag timeout: 120_000
      test "#{surface} #{how}: B deletes the item A types in: never written into the next item",
           c do
        a = open_plain(c, unquote(surface))
        put_items(c, [item("r2", "beta")])
        assert eventually(fn -> length(form(a)["items"]) == 1 end)

        fields = %{
          "doc[items][0]._type" => "item",
          "doc[items][0]._key" => "r1",
          "doc[items][0].name" => "alpha A",
          "doc[items][1]._type" => "item",
          "doc[items][1]._key" => "r2",
          "doc[items][1].name" => "beta"
        }

        in_flight(a, unquote(how), "doc[items][0].name", fields)

        assert stored(c)["items"] |> by_key("name") == %{"r2" => "beta"}
      end
    end
  end
end
