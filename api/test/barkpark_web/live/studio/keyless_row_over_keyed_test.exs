defmodule BarkparkWeb.Studio.KeylessRowOverKeyedTest do
  @moduledoc """
  task-bbaf091ad00e7cda (#29165 review, W3). A list of composite rows holds a
  keyless row. B puts a keyed row in front of it; A's page, typed on the
  first draw, posts the keyless row at its old index, where B's keyed row is
  now. The save fold wrote it there by index, over B's row. A composite row
  always posts its `_key` (`ArrayField`, `ObjectForm`), so its keyless leaves
  over a keyed row are dropped, and A's words are shown in the banner.

  Each post is the page's own: the inputs the editor form draws, read from
  the rendered page, with A's edit put in.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  alias Barkpark.Content.Codelists
  alias BarkparkWeb.EditorPost

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)
    list_id = "onixedit:w3-#{System.unique_integer([:positive])}"
    lang = fn label -> [%{language: "eng", label: label}] end

    {:ok, _} =
      Codelists.register("onixedit", list_id, %{
        issue: "1",
        name: "W3",
        values: [
          %{code: "A1", translations: lang.("A one")},
          %{code: "B2", translations: lang.("B two")}
        ]
      })

    row = %{
      "type" => "composite",
      "name" => "row",
      "title" => "Row",
      "fields" => [
        %{"name" => "rt", "title" => "rt", "type" => "richText"},
        %{"name" => "note", "title" => "Note", "type" => "string"}
      ]
    }

    fields = [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "rows", "title" => "Rows", "type" => "arrayOf", "of" => row},
      %{
        "name" => "refs",
        "title" => "Refs",
        "type" => "arrayOf",
        "of" => %{"type" => "reference", "to" => [c.type]}
      },
      %{
        "name" => "locs",
        "title" => "Locs",
        "type" => "arrayOf",
        "of" => %{"type" => "localizedText", "languages" => ["nob", "eng"], "format" => "plain"}
      },
      %{
        "name" => "codes",
        "title" => "Codes",
        "type" => "arrayOf",
        "of" => %{"name" => "code", "type" => "codelist", "codelistId" => list_id}
      }
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => c.type, "title" => "W3", "visibility" => "public", "fields" => fields},
        "production"
      )

    c
  end

  defp row(key, texts, note) do
    blocks = for {t, j} <- Enum.with_index(texts), do: block("b#{key}#{j}", t)
    r = %{"_type" => "row", "rt" => blocks, "note" => note}
    if key, do: Map.put(r, "_key", key), else: r
  end

  defp store(c, content) do
    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "T0", "content" => content},
        "production"
      )
  end

  # On error :warn: an array of localized text draws one id per language for
  # every row (task-0619faf87a2a931e), which LiveViewTest refuses.
  defp tab(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path, on_error: :warn)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp rows(content),
    do: Enum.map(content["rows"] || [], &{&1["_key"], words(&1["rt"]), &1["note"]})

  # B's save, and A's socket taking it (A's page keeps its first draw).
  defp b_saves(c, a, content) do
    store(c, content)

    assert eventually(fn -> rows(form(a)) == rows(content) end),
           "A's socket did not take B's save"
  end

  # The editor form's inputs as the page draws them, by name.
  defp drawn(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#editor-form input[name^="doc["], #editor-form textarea[name^="doc["]))
    |> Enum.map(fn node ->
      [name] = LazyHTML.attribute(node, "name")

      value =
        case LazyHTML.tag(node) do
          ["textarea"] -> LazyHTML.text(node)
          _ -> List.first(LazyHTML.attribute(node, "value")) || ""
        end

      {name, value}
    end)
    |> Map.new()
  end

  defp owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  # A's post of a draw (`drawn/1`, `owners/1`), with A's edits
  # (`[{name, value}]`).
  defp a_posts(view, {inputs, owners}, edits, how \\ "autosave") do
    # The first edit is the input the change came from.
    [{target, _} | _] = edits

    params =
      inputs
      |> Map.merge(Map.new(edits))
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{"_target" => [target], "_bp_rt_owner" => owners})

    EditorPost.hook(view, how, params)
  end

  defp draw(view), do: {drawn(view), owners(view)}

  defp lost(a),
    do:
      for(
        {{:lost, name}, _} <- :sys.get_state(a.pid).socket.assigns[:editor_rt_clash] || %{},
        do: name
      )

  for surface <- [:desk, :studio] do
    @surface surface

    for how <- ["autosave", "save"] do
      @how how
      test "#{surface} #{how} W3: B puts keyed r0 in front of the keyless row and edits that row; A types in it: B kept, A's words in the banner",
           c do
        store(c, %{"rows" => [row(nil, ["one", "two"], "n1"), row("r2", ["three"], "n3")]})
        a = tab(c, @surface)
        first = draw(a)

        b_saves(c, a, %{
          "rows" => [
            row("r0", ["zero"], "z0"),
            row(nil, ["one", "two B"], "n1"),
            row("r2", ["three"], "n3")
          ]
        })

        html = a_posts(a, first, [{"doc[rows][0].rt", "<p>ONE</p><p>two</p>"}], @how)

        # Before: A's keyless row written into r0, B's "zero" lost, no banner.
        assert rows(stored(c)) == [
                 {"r0", ["zero"], "z0"},
                 {nil, ["one", "two B"], "n1"},
                 {"r2", ["three"], "n3"}
               ],
               "A's keyless row was written into B's row: #{inspect(rows(stored(c)))}"

        assert "doc[rows][0].rt" in lost(a)
        # A's untouched note in the dropped row is not A's text to copy.
        refute "doc[rows][0].note" in lost(a)
        assert html =~ "doc-conflict-banner"
      end
    end

    # task-41218d31b9a913c4: a dropped plain subfield's words reached no
    # banner (`DroppedRows` read rich text only).
    for how <- ["autosave", "save"] do
      @how how
      test "#{surface} #{how} W3, a plain subfield: A's note in the keyless row is never written into B's r0, and is shown",
           c do
        store(c, %{"rows" => [row(nil, ["one"], "n1"), row("r2", ["three"], "n3")]})
        a = tab(c, @surface)
        first = draw(a)

        b_saves(c, a, %{
          "rows" => [
            row("r0", ["zero"], "z0"),
            row(nil, ["one"], "n1"),
            row("r2", ["three"], "n3")
          ]
        })

        html = a_posts(a, first, [{"doc[rows][0].note", "n1 A"}], @how)

        assert rows(stored(c)) == [
                 {"r0", ["zero"], "z0"},
                 {nil, ["one"], "n1"},
                 {"r2", ["three"], "n3"}
               ],
               "A's note was written into B's row: #{inspect(rows(stored(c)))}"

        # Before: nothing in the banner, A's "n1 A" lost with no notice.
        assert lost(a) == ["doc[rows][0].note"], "A's note is in no banner: #{inspect(lost(a))}"
        assert html =~ "doc-conflict-lost"
        assert html =~ "n1 A"
      end
    end

    test "#{surface} W1, a plain subfield: B removes the keyless row; A's typed note is shown, nothing written",
         c do
      store(c, %{"rows" => [row(nil, ["one"], "n1"), row("r2", ["three"], "n3")]})
      a = tab(c, @surface)
      first = draw(a)

      b_saves(c, a, %{"rows" => [row("r0", ["zero"], "z0"), row("r2", ["three"], "n3")]})

      html = a_posts(a, first, [{"doc[rows][0].note", "n1 A"}])

      assert rows(stored(c)) == [{"r0", ["zero"], "z0"}, {"r2", ["three"], "n3"}]
      assert lost(a) == ["doc[rows][0].note"]
      assert html =~ "n1 A"
    end

    test "#{surface} control: B removes the keyless row; A's untouched note is not shown, A's typed rich text is",
         c do
      store(c, %{"rows" => [row(nil, ["one"], "n1"), row("r2", ["three"], "n3")]})
      a = tab(c, @surface)
      first = draw(a)

      b_saves(c, a, %{"rows" => [row("r0", ["zero"], "z0"), row("r2", ["three"], "n3")]})

      a_posts(a, first, [{"doc[rows][0].rt", "<p>one A</p>"}])

      assert lost(a) == ["doc[rows][0].rt"]
    end

    # A keyless row can't vouch for an earlier write at its index (#29332
    # review, N5): the note is shown again; nothing is written.
    test "#{surface} keyless: A typed its note before B's insert; it was written, and a later drop shows it again",
         c do
      store(c, %{"rows" => [row(nil, ["one"], "n1"), row("r2", ["three"], "n3")]})
      a = tab(c, @surface)
      first = draw(a)
      a_posts(a, first, [{"doc[rows][0].note", "n1 A"}])
      assert {nil, ["one"], "n1 A"} in rows(stored(c))

      b_saves(c, a, %{
        "rows" => [
          row("r0", ["zero"], "z0"),
          row(nil, ["one"], "n1 A"),
          row("r2", ["three"], "n3")
        ]
      })

      a_posts(a, first, [{"doc[rows][0].rt", "<p>one A</p>"}, {"doc[rows][0].note", "n1 A"}])

      assert {nil, ["one"], "n1 A"} in rows(stored(c))
      assert Enum.sort(lost(a)) == ["doc[rows][0].note", "doc[rows][0].rt"]
    end

    # Controls: rows that post no `_key` though stored with one keep the
    # index fold, and A's own rows are written.
    test "#{surface} control: a keyed localized text row, posted with no _key, is written at its index",
         c do
      store(c, %{
        "locs" => [
          %{"_key" => "l0", "nob" => "null", "eng" => "zero"},
          %{"_key" => "l1", "nob" => "en", "eng" => "one"}
        ]
      })

      a = tab(c, @surface)
      a_posts(a, draw(a), [{"doc[locs][1].eng", "one A"}])

      assert stored(c)["locs"] == [
               %{"_key" => "l0", "nob" => "null", "eng" => "zero"},
               %{"_key" => "l1", "nob" => "en", "eng" => "one A"}
             ]
    end

    test "#{surface} control: a keyed reference row, posted with no _key, is written at its index",
         c do
      store(c, %{
        "refs" => [
          %{"_type" => "reference", "_key" => "f0", "_ref" => c.id <> "-link"},
          %{"_type" => "reference", "_key" => "f1", "_ref" => c.id <> "-link"}
        ]
      })

      a = tab(c, @surface)
      a_posts(a, draw(a), [{"doc[refs][1]", c.id}])

      assert Enum.map(stored(c)["refs"], & &1["_ref"]) == [c.id <> "-link", c.id]
    end

    test "#{surface} control: a codelist row is written at its index", c do
      store(c, %{"codes" => ["A1", "B2"]})
      a = tab(c, @surface)
      a_posts(a, draw(a), [{"doc[codes][1]", "A1"}, {"doc[codes][0]", "A1"}])
      assert stored(c)["codes"] == ["A1", "A1"]
    end

    test "#{surface} control: a row stored with `_key` \"\" is keyless: A's edit in it is written",
         c do
      store(c, %{
        "rows" => [Map.put(row(nil, ["one"], "n1"), "_key", ""), row("r2", ["two"], "n2")]
      })

      a = tab(c, @surface)
      html = a_posts(a, draw(a), [{"doc[rows][0].rt", "<p>one A</p>"}])
      assert [{"", ["one A"], "n1"}, {"r2", ["two"], "n2"}] = rows(stored(c))
      assert lost(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A's own keyless row in a list nobody keyed is written", c do
      store(c, %{"rows" => [row(nil, ["one"], "n1"), row(nil, ["two"], "n2")]})
      a = tab(c, @surface)
      html = a_posts(a, draw(a), [{"doc[rows][1].rt", "<p>two A</p>"}])
      assert rows(stored(c)) == [{nil, ["one"], "n1"}, {nil, ["two A"], "n2"}]
      assert lost(a) == []
      refute html =~ "doc-conflict-banner"
    end

    for {list, rows0} <- [
          {"keyed", quote(do: [row("r1", ["one"], "n1")])},
          {"keyless", quote(do: [row(nil, ["one"], "n1")])}
        ] do
      test "#{surface} control: A adds a row to a #{list} list and types in it: written", c do
        store(c, %{"rows" => unquote(rows0)})
        a = tab(c, @surface)

        EditorPost.press(a, "array_op", %{
          "action" => "add_row",
          "field" => "rows",
          "path" => "doc[rows]"
        })

        assert eventually(fn -> length(stored(c)["rows"] || []) == 2 end)
        [first_key, new_key] = Enum.map(stored(c)["rows"], & &1["_key"])

        html = a_posts(a, draw(a), [{"doc[rows][1].rt", "<p>new A</p>"}])

        assert [{^first_key, ["one"], "n1"}, {^new_key, ["new A"], _}] = rows(stored(c))
        assert lost(a) == []
        refute html =~ "doc-conflict-banner"
      end
    end

    test "#{surface} control: A duplicates a keyed row and types in the copy: written", c do
      store(c, %{"rows" => [row("r1", ["one"], "n1"), row("r2", ["two"], "n2")]})
      a = tab(c, @surface)

      EditorPost.press(a, "array_op", %{
        "action" => "duplicate_row",
        "field" => "rows",
        "path" => "doc[rows]",
        "index" => "0"
      })

      assert eventually(fn -> length(stored(c)["rows"] || []) == 3 end)
      [_, copy, _] = Enum.map(stored(c)["rows"], & &1["_key"])
      assert copy not in [nil, "r1", "r2"]

      html = a_posts(a, draw(a), [{"doc[rows][1].rt", "<p>one copy</p>"}])

      assert rows(stored(c)) == [
               {"r1", ["one"], "n1"},
               {copy, ["one copy"], "n1"},
               {"r2", ["two"], "n2"}
             ]

      assert lost(a) == []
      refute html =~ "doc-conflict-banner"
    end
  end
end
