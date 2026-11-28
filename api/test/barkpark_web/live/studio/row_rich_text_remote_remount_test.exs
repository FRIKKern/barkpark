defmodule BarkparkWeb.Studio.RowRichTextRemoteRemountTest do
  @moduledoc """
  task-d24c493daaefc627 (K2, #29332 review). The desk draws an object
  array whose `of` is one map as items and names a keyed item's inputs by
  its `_key` (`rows[_key=="r1"].rt`), with no index. The rich text
  wrapper's id hashed only the `_key`, so when another editor's save
  reordered the rows, LiveView moved the ignored wrapper with its row and
  its input kept the old index's name: the page drew r1's text under
  `rows[0]`, now r2's. The Studio's ids, and the desk's for a list `of`,
  carry the index and remount.

  On the desk the wrapper id now hashes the input name too, so a moved item
  remounts under its new index.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  alias BarkparkWeb.Components.Fields.CompositeField
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
        %{"name" => "note", "title" => "Note", "type" => "string"}
      ]
    }

    fields = [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      %{"name" => "rows", "title" => "Rows", "type" => "arrayOf", "of" => row}
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => c.type, "title" => "Rows", "visibility" => "public", "fields" => fields},
        "production"
      )

    c
  end

  defp row(key, text, note) do
    r = %{"_type" => "row", "rt" => [block("b#{key}#{text}", text)], "note" => note}
    if key, do: Map.put(r, "_key", key), else: r
  end

  defp store(c, rows) do
    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "T0", "content" => %{"rows" => rows}},
        "production"
      )
  end

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

  # The digest the owner entry of `name` names.
  defp owner_draw(view, name) do
    Enum.find_value(owners(view), fn o ->
      case Jason.decode!(o) do
        [^name, _key, digest | _] -> digest
        _ -> nil
      end
    end)
  end

  defp wrapper_ids(view) do
    ~r/id="(bp-rt-sub-[^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, id] -> id end)
  end

  # The page's post, as a browser sends it: the drawn inputs with A's edit,
  # the owner entries, and the seen number of row 0's rich text from mount.
  defp a_posts(a, seq, {name, value}, how) do
    params =
      drawn(a)
      |> Map.put(name, value)
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_target" => [name],
        "_bp_rt_owner" => owners(a),
        "_bp_rt_seen" => ["doc[rows][0].rt|#{seq}"]
      })

    EditorPost.hook(a, how, params)
  end

  defp mount_seq(a) do
    assert_push_event(a, "bp:rt-remote", %{values: %{"doc[rows][0].rt" => v}}, 3_000)
    v.seq
  end

  defp draw(text), do: CompositeField.drawn_digest([block("x", text)])

  # B's save, and A's socket taking it (A's page keeps its ignored editors).
  defp b_saves(c, a, rows) do
    store(c, rows)
    assert eventually(fn -> rows(form(a)) == rows(%{"rows" => rows}) end)
  end

  # The drawn `{_key, rt}` per index, as the page would post them.
  defp keyed_draw(a) do
    d = drawn(a)

    for j <- 0..2,
        Map.has_key?(d, "doc[rows][#{j}].rt"),
        do: {d["doc[rows][#{j}]._key"], d["doc[rows][#{j}].rt"]}
  end

  for surface <- [:desk, :studio], how <- ["autosave", "save"] do
    @surface surface
    @how how
    @tg "#{surface} #{how}"

    test "#{@tg} K2: B reorders keyed rows; each index draws its row's rich text and owner", c do
      store(c, [row("r1", "one", "n1"), row("r2", "three", "n3")])
      a = tab(c, @surface)
      b_saves(c, a, [row("r2", "three", "n3"), row("r1", "one", "n1")])

      # Before (desk): [{"r2", "<p>one</p>"}, {"r1", "<p>three</p>"}].
      assert keyed_draw(a) == [{"r2", "<p>three</p>"}, {"r1", "<p>one</p>"}]
      assert owner_draw(a, "doc[rows][0].rt") == draw("three")
    end

    test "#{@tg} control K2b: B reorders, then removes r1; A edits row 0: r2's text kept", c do
      store(c, [row("r1", "one", "n1"), row("r2", "three", "n3")])
      a = tab(c, @surface)
      seq = mount_seq(a)
      b_saves(c, a, [row("r2", "three", "n3"), row("r1", "one", "n1")])
      b_saves(c, a, [row("r2", "three", "n3")])
      a_posts(a, seq, {"doc[rows][0].note", "n3 A"}, @how)

      # Held since #29356 (the map `of` walk), before this change too.
      assert rows(stored(c)) == [{"r2", ["three"], "n3 A"}]
    end

    test "#{@tg} control: B edits r2's note in place; A's editors keep their mount", c do
      store(c, [row("r1", "one", "n1"), row("r2", "three", "n3")])
      a = tab(c, @surface)
      ids = wrapper_ids(a)
      b_saves(c, a, [row("r1", "one", "n1"), row("r2", "three", "n3 B")])
      assert wrapper_ids(a) == ids
    end

    test "#{@tg} control: B reorders keyless rows; A's editors keep their mount", c do
      store(c, [row(nil, "pee", "p"), row(nil, "queue", "q")])
      a = tab(c, @surface)
      ids = wrapper_ids(a)
      b_saves(c, a, [row(nil, "queue", "q"), row(nil, "pee", "p")])
      # A keyless row has no key to follow: another editor's change to it is
      # the remote push's (`RichTextRemote`), not a remount.
      assert wrapper_ids(a) == ids
    end
  end
end
