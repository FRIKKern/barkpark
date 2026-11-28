defmodule BarkparkWeb.Studio.LostBannerKeylessOwnRemovalTest do
  @moduledoc """
  task-a9d2941b9310bf0b (#29319 review, G2). A row A removed itself is
  not another editor's doing: a post the page sent before it redrew
  carries it, and it is not shown as lost. The set of A's removals was
  keyed by `_key`, so a keyless row A removed was not recognized, and its
  rich text (N4rt) and plain leaves (N4) showed in the lost banner.

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
      %{"name" => "rows", "title" => "Rows", "type" => "arrayOf", "of" => [row]}
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

  # The owner entry `entry` for `name`, naming the draw of `text`.
  defp drew(entry, name, text) do
    case Jason.decode!(entry) do
      [^name, key, _digest | rest] ->
        draw = BarkparkWeb.Components.Fields.CompositeField.drawn_digest([block("bq0", text)])
        Jason.encode!([name, key, draw | rest])

      _ ->
        entry
    end
  end

  defp removes(a, index) do
    EditorPost.press(a, "array_op", %{
      "action" => "remove_row",
      "field" => "rows",
      "path" => "doc[rows]",
      "index" => to_string(index)
    })
  end

  for surface <- [:desk, :studio], how <- ["autosave", "save"] do
    @surface surface
    @how how

    test "#{surface} #{how} N4rt: A types in its keyless row's rich text, removes the row; a stale post: not shown",
         c do
      store(c, %{"rows" => [rown(nil, "pee", "p", true), rown("r2", "three", "n3", true)]})
      a = tab(c, @surface)
      first = draw(a)
      a_posts(a, first, [{"doc[rows][0].rt", "<p>pee A</p>"}])
      removes(a, 0)
      assert eventually(fn -> length(stored(c)["rows"]) == 1 end)

      a_posts(a, first, [{"doc[rows][0].rt", "<p>pee A2</p>"}], @how)

      assert rows(stored(c)) == [{"r2", ["three"], "n3", true}]
      # Before: lost == ["doc[rows][0].rt"], A's own removal shown as lost.
      assert lost(a) == [], "A's own removal is in the lost banner: #{inspect(lost(a))}"
    end

    test "#{surface} #{how} N4: A types the keyless row's note, removes the row; a stale post: not shown",
         c do
      store(c, %{"rows" => [rown(nil, "pee", "p", true), rown("r2", "three", "n3", true)]})
      a = tab(c, @surface)
      first = draw(a)
      a_posts(a, first, [{"doc[rows][0].note", "p A"}])
      removes(a, 0)
      assert eventually(fn -> length(stored(c)["rows"]) == 1 end)

      a_posts(a, first, [{"doc[rows][0].note", "p A2"}], @how)

      assert rows(stored(c)) == [{"r2", ["three"], "n3", true}]
      assert lost(a) == [], "A's own removal is in the lost banner: #{inspect(lost(a))}"
    end

    test "#{surface} #{how} N4m: A removes its keyless row with a note edit never autosaved: not shown",
         c do
      store(c, %{"rows" => [rown(nil, "pee", "p", true), rown("r2", "three", "n3", true)]})
      a = tab(c, @surface)
      first = draw(a)
      removes(a, 0)
      assert eventually(fn -> length(stored(c)["rows"]) == 1 end)

      a_posts(a, first, [{"doc[rows][0].note", "p A"}], @how)

      assert lost(a) == [], "A's own removal is in the lost banner: #{inspect(lost(a))}"
    end

    # Controls: another editor's removal of a keyless row is shown. The
    # page's post targets the input A typed in (a note posted beside it is
    # not A's change).
    for {leaf, html} <- [{"rt", "<p>pee A</p>"}, {"note", "p A"}] do
      @leaf leaf
      @html html
      test "#{surface} #{how} control: B removes the keyless row A typed in (#{leaf}): shown",
           c do
        store(c, %{"rows" => [rown(nil, "pee", "p", true), rown("r2", "three", "n3", true)]})
        a = tab(c, @surface)
        first = draw(a)
        b_saves(c, a, %{"rows" => [rown("r2", "three", "n3", true)]})

        a_posts(a, first, [{"doc[rows][0].#{@leaf}", @html}], @how)

        assert rows(stored(c)) == [{"r2", ["three"], "n3", true}]
        assert lost(a) == ["doc[rows][0].#{@leaf}"]
      end

      test "#{surface} #{how} control: A removes keyless P; B removes keyless Q, which A's page drew and typed in (#{leaf}): shown",
           c do
        store(c, %{
          "rows" => [
            rown(nil, "pee", "p", true),
            rown(nil, "queue", "q", true),
            rown("r2", "three", "n3", true)
          ]
        })

        a = tab(c, @surface)
        removes(a, 0)
        assert eventually(fn -> length(stored(c)["rows"]) == 2 end)
        # The page's editor at index 0 drew Q (its owner entry names Q's
        # draw). One kept in its ignored wrapper names P's, and can't be
        # told from a stale post of P.
        {inputs, owners} = draw(a)
        second = {inputs, Enum.map(owners, &drew(&1, "doc[rows][0].rt", "queue"))}
        b_saves(c, a, %{"rows" => [rown("r2", "three", "n3", true)]})

        # Q's editor shows Q's words: the rt input posts them.
        edits = [{"doc[rows][0].#{@leaf}", String.replace(@html, "pee", "queue")}]
        edits = if @leaf == "rt", do: edits, else: edits ++ [{"doc[rows][0].rt", "<p>queue</p>"}]
        a_posts(a, second, edits, @how)

        assert rows(stored(c)) == [{"r2", ["three"], "n3", true}]
        assert lost(a) == ["doc[rows][0].#{@leaf}"]
      end
    end
  end
end
