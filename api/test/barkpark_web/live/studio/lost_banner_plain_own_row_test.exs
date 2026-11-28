defmodule BarkparkWeb.Studio.LostBannerPlainOwnRowTest do
  @moduledoc """
  task-56e816b101f71719 (#29319 review, G1). A dropped plain subfield A
  changed was hidden when ANY row of its parent held the same value: A's
  "TODO" typed into the keyless row was lost with no notice because B's r2
  says "TODO", and a box A ticked off was hidden because a sibling reads
  false. It is hidden only when A's own earlier post wrote that value.

  Each post is the page's own: the inputs the editor form draws, with A's
  edit put in.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  alias BarkparkWeb.EditorPost

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)

    row = %{
      "type" => "composite",
      "name" => "row",
      "title" => "Row",
      "fields" => [
        %{"name" => "rt", "title" => "rt", "type" => "richText"},
        %{"name" => "note", "title" => "Note", "type" => "string"},
        %{"name" => "done", "title" => "Done", "type" => "boolean"}
      ]
    }

    fields = [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "rows", "title" => "Rows", "type" => "arrayOf", "of" => row}
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => c.type, "title" => "G1", "visibility" => "public", "fields" => fields},
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
    do: Enum.map(content["rows"] || [], &{&1["_key"], words(&1["rt"]), &1["note"], &1["done"]})

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
    |> LazyHTML.query(
      ~s(#editor-form input[name^="doc["], #editor-form textarea[name^="doc["], #editor-form select[name^="doc["])
    )
    |> Enum.reject(fn node ->
      LazyHTML.attribute(node, "type") in [["checkbox"], ["radio"]] and
        LazyHTML.attribute(node, "checked") == []
    end)
    |> Enum.map(fn node ->
      [name] = LazyHTML.attribute(node, "name")

      value =
        case LazyHTML.tag(node) do
          ["textarea"] ->
            LazyHTML.text(node)

          ["select"] ->
            node
            |> LazyHTML.query("option[selected]")
            |> Enum.flat_map(&LazyHTML.attribute(&1, "value"))
            |> List.first() || ""

          _ ->
            List.first(LazyHTML.attribute(node, "value")) || ""
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

  defp rown(key, text, note, done), do: Map.put(row(key, [text], note), "done", done)

  for surface <- [:desk, :studio], how <- ["autosave", "save"] do
    @surface surface
    @how how

    test "#{surface} #{how} N1: A types TODO into the keyless row, B inserts r0, r2 says TODO: shown, nothing written",
         c do
      store(c, %{"rows" => [rown(nil, "one", "n1", true), rown("r2", "three", "TODO", true)]})
      a = tab(c, @surface)
      first = draw(a)

      b_saves(c, a, %{
        "rows" => [
          rown("r0", "zero", "z0", true),
          rown(nil, "one", "n1", true),
          rown("r2", "three", "TODO", true)
        ]
      })

      html = a_posts(a, first, [{"doc[rows][0].note", "TODO"}], @how)

      assert rows(stored(c)) == [
               {"r0", ["zero"], "z0", true},
               {nil, ["one"], "n1", true},
               {"r2", ["three"], "TODO", true}
             ]

      # Before: lost == [], no banner: A's "TODO" lost with no notice.
      assert lost(a) == ["doc[rows][0].note"], "A's TODO is in no banner: #{inspect(lost(a))}"
      assert html =~ "doc-conflict-lost"
    end

    test "#{surface} #{how} boolean: A ticks off the keyless row's box, B inserts r0, r2's box is off: shown",
         c do
      store(c, %{"rows" => [rown(nil, "one", "n1", true), rown("r2", "three", "n3", false)]})
      a = tab(c, @surface)
      first = draw(a)

      b_saves(c, a, %{
        "rows" => [
          rown("r0", "zero", "z0", false),
          rown(nil, "one", "n1", true),
          rown("r2", "three", "n3", false)
        ]
      })

      html = a_posts(a, first, [{"doc[rows][0].done", "false"}], @how)

      assert {nil, ["one"], "n1", true} in rows(stored(c))
      assert lost(a) == ["doc[rows][0].done"], "A's change is in no banner: #{inspect(lost(a))}"
      assert html =~ "doc-conflict-lost"
    end

    # A keyless row has no identity: an earlier write at its index can't
    # vouch for it (#29332 review, N5).
    test "#{surface} #{how} keyless: A's TODO was written before B's insert: shown again on a later drop",
         c do
      store(c, %{"rows" => [rown(nil, "one", "n1", true), rown("r2", "three", "n3", true)]})
      a = tab(c, @surface)
      first = draw(a)
      a_posts(a, first, [{"doc[rows][0].note", "TODO"}])
      assert {nil, ["one"], "TODO", true} in rows(stored(c))

      b_saves(c, a, %{
        "rows" => [
          rown("r0", "zero", "z0", true),
          rown(nil, "one", "TODO", true),
          rown("r2", "three", "n3", true)
        ]
      })

      a_posts(
        a,
        first,
        [{"doc[rows][0].rt", "<p>one A</p>"}, {"doc[rows][0].note", "TODO"}],
        @how
      )

      assert {nil, ["one"], "TODO", true} in rows(stored(c))
      assert Enum.sort(lost(a)) == ["doc[rows][0].note", "doc[rows][0].rt"]
    end

    test "#{surface} #{how} control: A's note in keyed k1 was written; B removes k1: not shown on the drop",
         c do
      store(c, %{"rows" => [rown("k1", "one", "n1", true), rown("r2", "three", "n3", true)]})
      a = tab(c, @surface)
      first = draw(a)
      a_posts(a, first, [{"doc[rows][0].note", "TODO"}])
      assert {"k1", ["one"], "TODO", true} in rows(stored(c))
      b_saves(c, a, %{"rows" => [rown("r2", "three", "n3", true)]})

      a_posts(
        a,
        first,
        [{"doc[rows][0].rt", "<p>one A</p>"}, {"doc[rows][0].note", "TODO"}],
        @how
      )

      assert rows(stored(c)) == [{"r2", ["three"], "n3", true}]
      assert lost(a) == ["doc[rows][0].rt"]
    end

    test "#{surface} #{how} control: A's untouched note and box in a dropped row are not shown",
         c do
      store(c, %{"rows" => [rown(nil, "one", "n1", true), rown("r2", "three", "n3", true)]})
      a = tab(c, @surface)
      first = draw(a)

      b_saves(c, a, %{
        "rows" => [
          rown("r0", "zero", "z0", true),
          rown(nil, "one", "n1", true),
          rown("r2", "three", "n3", true)
        ]
      })

      a_posts(a, first, [{"doc[rows][0].rt", "<p>one A</p>"}], @how)

      assert lost(a) == ["doc[rows][0].rt"]
    end
  end

  # A Save of the page with no `_target`, as `phx-submit` posts it.
  defp no_target(view, {inputs, owners}) do
    params =
      inputs
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.put("_bp_rt_owner", owners)

    EditorPost.hook(view, "save", params)
  end

  defp plain_wrote(a), do: :sys.get_state(a.pid).socket.assigns[:editor_rt_plain_wrote]

  for surface <- [:desk, :studio] do
    @surface surface

    # #29332 review, N5b: the record named an index, and Q took P's.
    test "#{surface} N5b: A ticks off P's box; B removes P, then inserts keyed r0; A ticks off Q's: shown",
         c do
      store(c, %{"rows" => [rown(nil, "pee", "p", true), rown(nil, "queue", "q", true)]})
      a = tab(c, @surface)
      a_posts(a, draw(a), [{"doc[rows][0].done", "false"}])
      b_saves(c, a, %{"rows" => [rown(nil, "queue", "q", true)]})
      second = draw(a)
      b_saves(c, a, %{"rows" => [rown("r0", "zero", "z0", true), rown(nil, "queue", "q", true)]})

      html = a_posts(a, second, [{"doc[rows][0].done", "false"}])

      assert {nil, ["queue"], "q", true} in rows(stored(c))
      # Before: lost == [], no banner: A's tick-off of Q hidden by P's.
      assert lost(a) == ["doc[rows][0].done"], "A's change is in no banner: #{inspect(lost(a))}"
      assert html =~ "doc-conflict-lost"
    end

    for save? <- [false, true] do
      @save save?
      test "#{surface} N5 save=#{save?}: A wrote TODO in P; B removes P, then inserts keyed r0; A types TODO into Q: shown",
           c do
        store(c, %{"rows" => [rown(nil, "pee", "p", true), rown(nil, "queue", "q", true)]})
        a = tab(c, @surface)
        a_posts(a, draw(a), [{"doc[rows][0].note", "TODO"}])
        if @save, do: no_target(a, draw(a))
        b_saves(c, a, %{"rows" => [rown(nil, "queue", "q", true)]})
        second = draw(a)

        b_saves(c, a, %{"rows" => [rown("r0", "zero", "z0", true), rown(nil, "queue", "q", true)]})

        a_posts(a, second, [{"doc[rows][0].note", "TODO"}])

        assert {nil, ["queue"], "q", true} in rows(stored(c))
        assert lost(a) == ["doc[rows][0].note"], "A's TODO is in no banner: #{inspect(lost(a))}"
      end
    end

    # #29332 review, A1: the Save cleared the record, then refilled it.
    test "#{surface} A1: after autosaves in keyed rows and a Save, the record is empty", c do
      store(c, %{"rows" => [rown("k1", "one", "n1", true), rown("r2", "three", "n3", true)]})
      a = tab(c, @surface)
      first = draw(a)
      a_posts(a, first, [{"doc[rows][0].note", "n1 A"}])
      a_posts(a, first, [{"doc[rows][1].note", "n3 A"}])
      assert map_size(plain_wrote(a)) == 2

      no_target(a, draw(a))

      assert plain_wrote(a) == %{}
    end
  end
end
