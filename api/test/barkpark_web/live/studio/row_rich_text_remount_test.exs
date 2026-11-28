defmodule BarkparkWeb.Studio.RowRichTextRemountTest do
  @moduledoc """
  task-dd336795aff64006 (#29349 review, Q6s). A keyless row's rich text
  editor sits in a `phx-update="ignore"` wrapper whose id was the same for
  any keyless row at one index. After A removed keyless row P, the editor
  at index 0 kept P's text and P's owner entry while Q moved up under it.
  A's next edit anywhere in row 0, even only Q's note, posted P's text, and
  the save wrote it over Q's.

  The wrapper id now carries a count of the times A's own array change put
  another row under that index, so the editor remounts and draws Q.

  Each post is the page's own: the inputs the editor form draws (an ignored
  wrapper keeps its old inputs in LiveViewTest as in a browser), its owner
  entries, and the `_bp_rt_seen` number the page took at mount.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity
  alias BarkparkWeb.Studio.StudioLive.RejoinForm

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
      %{"name" => "rows", "title" => "Rows", "type" => "arrayOf", "of" => [row]}
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

  defp op(a, action, index) do
    EditorPost.press(a, "array_op", %{
      "action" => action,
      "field" => "rows",
      "path" => "doc[rows]",
      "index" => to_string(index)
    })
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

  # The desk's Mod+Z / Mod+Shift+Z with nothing focused (`DocUndo`).
  defp undo(c, a, redo? \\ false) do
    mark = %{PostIdentity.key() => PostIdentity.value("production", c.type, c.id)}
    render_hook(a, "desk-undo", Map.put(mark, "redo", redo?))
  end

  # Every index draws the stored row there: its rich text input and owner.
  defp consistent?(c, a) do
    stored(c)["rows"]
    |> Enum.with_index()
    |> Enum.all?(fn {r, i} ->
      text = Enum.join(words(r["rt"]), " ")

      owner_draw(a, "doc[rows][#{i}].rt") == draw(text) and
        (drawn(a)["doc[rows][#{i}].rt"] || "") =~ text
    end)
  end

  defp texts(c), do: Enum.map(stored(c)["rows"], &words(&1["rt"]))

  defp list_path(c, :desk), do: "#{c.root}/_desk/#{c.type}"
  defp list_path(c, :studio), do: "#{c.root}/#{c.type}"

  defp doc_path(c, :desk), do: "#{c.root}/_desk/#{c.type};#{c.id}"
  defp doc_path(c, :studio), do: "#{c.root}/#{c.type}/#{c.id}"

  # The page's join params as `BarkparkFormConnectParams` sends them.
  defp join_params(a) do
    form = a |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#editor-form")
    [doc] = LazyHTML.attribute(form, "phx-value-_bp_doc")
    [gen] = LazyHTML.attribute(form, "data-bp-form-gen")

    page =
      case LazyHTML.attribute(form, "data-bp-row-mounts") do
        [rows] -> %{"doc" => doc, "gen" => gen, "rows" => rows}
        [] -> %{"doc" => doc, "gen" => gen}
      end

    %{"_mounts" => 1, "_bp_form" => page}
  end

  # A new socket as a rejoin's first patch reads it (`RejoinFormGenTest`):
  # LiveViewTest joins with `_mounts: 0` and cannot send `_bp_form`.
  defp rejoined(c, surface, params) do
    {:ok, view, _} = live(c.conn, list_path(c, surface), on_error: :warn)

    flags =
      %{editor_rejoined?: true, editor_rejoin_form: RejoinForm.from_params(params)}
      |> Map.merge(if surface == :desk, do: %{desk_rejoin?: true}, else: %{})

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.merge(&1, flags))
    end)

    render_patch(view, doc_path(c, surface))
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  test "the page's row mounts are read as bounded counts of row paths" do
    alias BarkparkWeb.Studio.StudioLive.Handlers.RowMounts
    assert RowMounts.parse(~s({"doc[rows][0]":2})) == %{"doc[rows][0]" => 2}
    assert RowMounts.parse(~s({"rows[0]":2})) == %{}
    assert RowMounts.parse(~s({"doc[rows][0]":0})) == %{}
    assert RowMounts.parse(~s({"doc[rows][0]":"2"})) == %{}
    assert RowMounts.parse(~s([1])) == %{}
    assert RowMounts.parse(String.duplicate("x", 20_000)) == %{}
    assert RowMounts.parse(nil) == %{}

    assert RowMounts.count(%{"doc[s][0]" => 1, "doc[s][0].items[2]" => 2}, "doc[s][0].items[2]") ==
             3

    assert RowMounts.count(%{"doc[s][1]" => 1}, "doc[s][0].items[1]") == 0
  end

  for surface <- [:desk, :studio], how <- ["autosave", "save"] do
    @surface surface
    @how how
    @tg "#{surface} #{how}"

    test "#{@tg} Q6s: A removes keyless P; A edits Q's note at index 0: Q's rich text kept", c do
      store(c, [row(nil, "pee", "p"), row(nil, "queue", "q"), row("r2", "three", "n3")])
      a = tab(c, @surface)
      seq = mount_seq(a)
      op(a, "remove_row", 0)
      assert eventually(fn -> length(stored(c)["rows"]) == 2 end)

      # Before: the editor at index 0 still drew P.
      assert drawn(a)["doc[rows][0].rt"] =~ "queue"
      assert owner_draw(a, "doc[rows][0].rt") == draw("queue")

      a_posts(a, seq, {"doc[rows][0].note", "q A"}, @how)

      # Before: [{nil, ["pee"], "q A"}, ...]: P's text over Q's.
      assert rows(stored(c)) == [{nil, ["queue"], "q A"}, {"r2", ["three"], "n3"}]
    end

    test "#{@tg} Q6r: A removes keyless P; A types in Q's rich text at index 0: written", c do
      store(c, [row(nil, "pee", "p"), row(nil, "queue", "q"), row("r2", "three", "n3")])
      a = tab(c, @surface)
      seq = mount_seq(a)
      op(a, "remove_row", 0)
      assert eventually(fn -> length(stored(c)["rows"]) == 2 end)
      a_posts(a, seq, {"doc[rows][0].rt", "<p>queue A</p>"}, @how)
      assert rows(stored(c)) == [{nil, ["queue A"], "q"}, {"r2", ["three"], "n3"}]
    end

    test "#{@tg} Q6m: A moves keyless Q up over P; A edits row 0's note: both rich texts kept",
         c do
      store(c, [row(nil, "pee", "p"), row(nil, "queue", "q")])
      a = tab(c, @surface)
      seq = mount_seq(a)
      op(a, "move_up", 1)
      assert eventually(fn -> rows(stored(c)) |> hd() |> elem(2) == "q" end)
      assert owner_draw(a, "doc[rows][0].rt") == draw("queue")
      assert owner_draw(a, "doc[rows][1].rt") == draw("pee")
      a_posts(a, seq, {"doc[rows][0].note", "q A"}, @how)
      assert rows(stored(c)) == [{nil, ["queue"], "q A"}, {nil, ["pee"], "p"}]
    end

    test "#{@tg} A removes row 1: row 1 draws the row now there; row 0 keeps its mount", c do
      store(c, [row(nil, "pee", "p"), row(nil, "queue", "q"), row(nil, "zed", "z")])
      a = tab(c, @surface)
      [first | _] = wrapper_ids(a)
      op(a, "remove_row", 1)
      assert eventually(fn -> length(stored(c)["rows"]) == 2 end)
      assert hd(wrapper_ids(a)) == first
      assert owner_draw(a, "doc[rows][1].rt") == draw("zed")
    end

    test "#{@tg} R1: A removes keyless P; the socket rejoins: the page's wrapper ids are drawn again",
         c do
      store(c, [row(nil, "pee", "p"), row(nil, "queue", "q"), row("r2", "three", "n3")])
      a = tab(c, @surface)
      op(a, "remove_row", 0)
      assert eventually(fn -> length(stored(c)["rows"]) == 2 end)
      ids = wrapper_ids(a)
      params = join_params(a)
      GenServer.stop(a.pid, :normal)

      # Before (no counts sent): ids back to the unsuffixed ones, so the page's
      # editors, with what was typed while the socket was down, are replaced.
      assert wrapper_ids(rejoined(c, @surface, params)) == ids

      refute wrapper_ids(
               rejoined(c, @surface, Map.update!(params, "_bp_form", &Map.delete(&1, "rows")))
             ) == ids
    end

    if surface == :desk do
      test "#{@tg} U1: A removes keyless P, then undoes it; A edits row 0: P's rich text kept",
           c do
        store(c, [row(nil, "pee", "p"), row(nil, "queue", "q"), row("r2", "three", "n3")])
        a = tab(c, @surface)
        seq = mount_seq(a)
        op(a, "remove_row", 0)
        assert eventually(fn -> length(stored(c)["rows"]) == 2 end)
        undo(c, a)
        assert eventually(fn -> length(stored(c)["rows"]) == 3 end)

        # Before: index 0 still drew Q at -m1 over P.
        assert consistent?(c, a)
        a_posts(a, seq, {"doc[rows][0].rt", drawn(a)["doc[rows][0].rt"] <> "<p>A</p>"}, @how)
        assert texts(c) == [["pee", "A"], ["queue"], ["three"]]
      end

      test "#{@tg} U2: A removes keyless P, undoes and redoes it: each index draws its row", c do
        store(c, [row(nil, "pee", "p"), row(nil, "queue", "q"), row("r2", "three", "n3")])
        a = tab(c, @surface)
        seq = mount_seq(a)
        op(a, "remove_row", 0)
        assert eventually(fn -> length(stored(c)["rows"]) == 2 end)
        undo(c, a)
        assert eventually(fn -> length(stored(c)["rows"]) == 3 end)
        undo(c, a, true)
        assert eventually(fn -> length(stored(c)["rows"]) == 2 end)
        assert consistent?(c, a)
        a_posts(a, seq, {"doc[rows][0].note", "q A"}, @how)
        assert rows(stored(c)) == [{nil, ["queue"], "q A"}, {"r2", ["three"], "n3"}]
      end

      test "#{@tg} U3: A moves keyless Q up, then undoes it: each index draws its row", c do
        store(c, [row(nil, "pee", "p"), row(nil, "queue", "q")])
        a = tab(c, @surface)
        seq = mount_seq(a)
        op(a, "move_up", 1)
        assert eventually(fn -> texts(c) == [["queue"], ["pee"]] end)
        undo(c, a)
        assert eventually(fn -> texts(c) == [["pee"], ["queue"]] end)
        assert consistent?(c, a)
        a_posts(a, seq, {"doc[rows][0].note", "p A"}, @how)
        assert rows(stored(c)) == [{nil, ["pee"], "p A"}, {nil, ["queue"], "q"}]
      end

      # replaced/2 compares each row's rich text at its index: a built write
      # that changes no row's rich text (here the undo writes the whole
      # rows value back) leaves every row editor, and words A has not
      # posted in one, where they are.
      # The desk's undo takes back an autosaved edit; a Save's is the save.
      if how == "autosave" do
        test "#{@tg} U5: A edits row 1's note, then undoes it (a built write of the rows): no row editor remounts",
             c do
          store(c, [row(nil, "pee", "p"), row(nil, "queue", "q")])
          a = tab(c, @surface)
          seq = mount_seq(a)
          ids = wrapper_ids(a)
          a_posts(a, seq, {"doc[rows][1].note", "q A"}, @how)
          assert eventually(fn -> rows(stored(c)) |> Enum.at(1) |> elem(2) == "q A" end)
          undo(c, a)
          assert eventually(fn -> rows(stored(c)) |> Enum.at(1) |> elem(2) == "q" end)
          assert wrapper_ids(a) == ids
          assert :sys.get_state(a.pid).socket.assigns[:editor_row_mounts] in [nil, %{}]
        end
      end

      test "#{@tg} U4: A inserts a row at 0, then undoes it: each index draws its row", c do
        store(c, [row(nil, "pee", "p"), row(nil, "queue", "q")])
        a = tab(c, @surface)
        seq = mount_seq(a)

        EditorPost.press(a, "array_op", %{
          "action" => "insert_row",
          "field" => "rows",
          "path" => "doc[rows]",
          "index" => "0",
          "member" => "row"
        })

        assert eventually(fn -> length(stored(c)["rows"]) == 3 end)
        undo(c, a)
        assert eventually(fn -> length(stored(c)["rows"]) == 2 end)
        assert consistent?(c, a)
        a_posts(a, seq, {"doc[rows][0].note", "p A"}, @how)
        assert rows(stored(c)) == [{nil, ["pee"], "p A"}, {nil, ["queue"], "q"}]
      end
    end

    test "#{@tg} control: two rows of one rich text; A removes row 0: row 0's editor keeps its mount",
         c do
      store(c, [row(nil, "same", "p"), row(nil, "same", "q")])
      a = tab(c, @surface)
      seq = mount_seq(a)
      [first | _] = wrapper_ids(a)
      op(a, "remove_row", 0)
      assert eventually(fn -> length(stored(c)["rows"]) == 1 end)
      # Its text and owner entry are the row's now there: nothing to redraw.
      assert hd(wrapper_ids(a)) == first
      assert owner_draw(a, "doc[rows][0].rt") == draw("same")
      a_posts(a, seq, {"doc[rows][0].note", "q A"}, @how)
      assert rows(stored(c)) == [{nil, ["same"], "q A"}]
    end

    test "#{@tg} control: A types in row 0 with no array change: its editor keeps its mount", c do
      store(c, [row(nil, "pee", "p"), row(nil, "queue", "q")])
      a = tab(c, @surface)
      seq = mount_seq(a)
      ids = wrapper_ids(a)
      a_posts(a, seq, {"doc[rows][0].rt", "<p>pee A</p>"}, @how)
      assert rows(stored(c)) == [{nil, ["pee A"], "p"}, {nil, ["queue"], "q"}]
      assert wrapper_ids(a) == ids
    end
  end
end
