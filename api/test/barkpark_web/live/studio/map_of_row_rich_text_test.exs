defmodule BarkparkWeb.Studio.MapOfRowRichTextTest do
  @moduledoc """
  task-9c10b827ba19f758. The schema takes an array's `of` as a list of
  member types or as ONE map descriptor (`SchemaDefinition`). The rich
  text walk of `RichTextRemote` followed `of` only as a list, so a map-of
  array's row rich text had no born values, no `RowDraws`, and none of the
  row guards: A's stale post merged into B's new row with no banner (R2r,
  T2, T2b), where the list shape holds it. These are the list shape's
  cases (`keyless_row_rerender_insert_test`,
  `keyless_row_two_save_insert_test`) on the map shape.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.Components.Fields.CompositeField
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live

  defp rt, do: %{"name" => "rt", "title" => "rt", "type" => "richText"}

  defp member(name, fields),
    do: %{"type" => "composite", "name" => name, "title" => name, "fields" => fields}

  # The map shape: `of` is the one member descriptor, not a list.
  defp array(name, of), do: %{"name" => name, "title" => name, "type" => "arrayOf", "of" => of}

  setup %{conn: conn} do
    c = setup_doc(conn)

    fields = [
      %{"name" => "title", "title" => "Title", "type" => "string"},
      array("sections", member("section", [array("items", member("item", [rt()]))]))
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Nested rows",
          "visibility" => "public",
          "fields" => fields
        },
        "production"
      )

    c
  end

  defp it(text), do: %{"_type" => "item", "rt" => [block("k" <> text, text)]}
  defp itk(text), do: %{"_type" => "item", "rt" => [block("b0", text)]}
  defp itk2(t1, t2), do: %{"_type" => "item", "rt" => [block("b0", t1), block("b1", t2)]}
  defp empty_it, do: %{"_type" => "item", "rt" => []}

  defp put_items(c, items) do
    sections = [%{"_type" => "section", "_key" => "s1", "items" => items}]

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "T0", "content" => %{"sections" => sections}},
        "production"
      )
  end

  defp tab(c, surface) do
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

  defp items_words(content),
    do: Enum.map(hd(content["sections"] || [%{}])["items"] || [], &words(&1["rt"]))

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  defp b_saves(c, a, items) do
    put_items(c, items)
    want = Enum.map(items, &words(&1["rt"]))

    assert eventually(fn -> items_words(form(a)) == want end),
           "A's socket did not take B's save: no test"
  end

  # A's post as its page sends it: the keyless items' HTML by the index the
  # page drew them at, with its owner entries. `seqs`: the seen number per
  # input name (`drain/1`), else 0.
  defp autosave(a, htmls, owners, seen, seqs \\ %{}) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params =
      htmls
      |> Enum.with_index()
      |> Enum.flat_map(fn {html, i} ->
        [
          {"doc[sections][0].items[#{i}]._type", "item"},
          {"doc[sections][0].items[#{i}].rt", html}
        ]
      end)
      |> Map.new()
      |> Map.merge(%{
        "doc[title]" => "T0",
        "doc[sections][0]._type" => "section",
        "doc[sections][0]._key" => "s1"
      })
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => ["doc[sections][0].items[0].rt"],
        "_bp_rt_owner" => owners
      })

    params =
      if seen,
        do:
          Map.put(
            params,
            "_bp_rt_seen",
            for(
              i <- 0..(length(htmls) - 1),
              n = "doc[sections][0].items[#{i}].rt",
              do: "#{n}|#{Map.get(seqs, n, 0)}"
            )
          ),
        else: params

    render_hook(a, "autosave", params)
  end

  # After a Reload that replaced A's held words in row 0: written on a post
  # with seen numbers; held with none (control J2R).
  defp reloaded(c, a, true) do
    assert items_words(stored(c)) == [["zed B", "new A"], ["alpha"]]
    assert held(a) == []
  end

  defp reloaded(c, a, false) do
    assert items_words(stored(c)) == [["zed B"], ["alpha"]]
    assert held(a) == ["doc[sections][0].items[0].rt"]
  end

  # Every bp:rt-remote push so far: the last number per input name.
  defp drain(a, acc \\ %{}) do
    {ref, _, _} = a.proxy

    receive do
      {^ref, {:push_event, "bp:rt-remote", %{values: v}}} ->
        drain(
          a,
          Enum.reduce(v, acc, fn {n, %{seq: s}}, m -> Map.update(m, n, s, &max(&1, s)) end)
        )
    after
      200 -> acc
    end
  end

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  # The owner entry a real page holds for index i after it drew there: in
  # the ignored wrapper, so it stays until a remount.
  defp own(owners, i), do: Enum.find(owners, &String.contains?(&1, "items[#{i}].rt"))

  # The entry a page re-rendered draws at index i for `value`.
  defp entry(i, value, like) do
    [_n, k, _d | rest] = Jason.decode!(like)

    Jason.encode!([
      "doc[sections][0].items[#{i}].rt",
      k,
      CompositeField.drawn_digest(value) | rest
    ])
  end

  for surface <- [:desk, :studio], seen <- [false, true] do
    @surface surface
    @seen seen
    @tag_name "#{surface}#{if seen, do: " seen", else: ""}"
    @row1 "doc[sections][0].items[1].rt"

    test "#{@tag_name} R2r: B inserts a keyless row before A's; A's page re-rendered; A types in row 0: B's row kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      html = autosave(a, ["<p>alpha</p><p>new A</p>", "<p>alpha</p>"], owners, @seen)

      # Before: [["zed B", "new A"], ["alpha"]], no banner.
      assert items_words(stored(c)) == [["zed B"], ["alpha"]],
             "A's words were merged into B's row: #{inspect(items_words(stored(c)))}"

      assert held(a) != []
      assert html =~ "doc-conflict-banner"
    end

    test "#{@tag_name} control J2: B inserts before, the page not re-rendered: B's row kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])
      html = autosave(a, ["<p>alpha</p><p>new A</p>"], o, @seen)
      assert items_words(stored(c)) == [["zed B"], ["alpha"]]
      assert held(a) != [] and html =~ "doc-conflict-banner"
    end

    # With no `_bp_rt_seen`, a post after a Reload that replaced A's held
    # words can't show it took the Reload: held, as before this change.

    test "#{@tag_name} T2: B adds an empty row in front, then types in it; A types in row 0: B's row kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [empty_it(), it("alpha")])
      b_saves(c, a, [it("zed B"), it("alpha")])
      q = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      html =
        autosave(
          a,
          ["<p>alpha</p><p>new A</p>", "<p>alpha</p>"],
          owners,
          @seen,
          Map.take(q, [@row1])
        )

      # Before: [["zed B", "new A"], ["alpha"]], no banner.
      assert items_words(stored(c)) == [["zed B"], ["alpha"]],
             "A's words were merged into B's row: #{inspect(items_words(stored(c)))}"

      assert held(a) != []
      assert html =~ "doc-conflict-banner"
    end

    test "#{@tag_name} T2b: B inserts zed B in front, then types more in it; A types in row 0: B's row kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])
      b_saves(c, a, [it("zed B more"), it("alpha")])
      q = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      html =
        autosave(
          a,
          ["<p>alpha</p><p>new A</p>", "<p>alpha</p>"],
          owners,
          @seen,
          Map.take(q, [@row1])
        )

      assert items_words(stored(c)) == [["zed B more"], ["alpha"]],
             "A's words were merged into B's row: #{inspect(items_words(stored(c)))}"

      assert held(a) != []
      assert html =~ "doc-conflict-banner"
    end

    # #29336 review, BT4, PU1, PU2: A's idle row 0 took B's pushes (its
    # seen is the last seq), and A types on B's value: built on the form's
    # row 0 now, not on A's old draw. The owner entry still names the old
    # draw (the editor sits in an ignored wrapper). Written, as on main.

    test "#{@tag_name} BT4: B adds an empty row in front, then types zed B; A's row 0 took both; A types on zed B: written",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [empty_it(), it("alpha")])
      b_saves(c, a, [it("zed B"), it("alpha")])
      q = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      autosave(a, ["<p>zed B</p><p>new A</p>", "<p>alpha</p>"], owners, @seen, q)

      # Before (#29336 r1): [["zed B"], ["alpha"]], held.
      assert items_words(stored(c)) == [["zed B", "new A"], ["alpha"]],
             "A's post on B's value was held: #{inspect(items_words(stored(c)))}"

      assert held(a) == []
    end

    # Seen path only. Without `_bp_rt_seen` the base is the draw the owner
    # entry names (alpha), and "a1" over B's empty row is a clash there:
    # still held with `KeylessShift`'s history read off (#29336 r2).
    if seen do
      test "#{@tag_name} PU1: B adds an empty row in front; A's row 0 took it; A types a1 there: written",
           c do
        put_items(c, [it("alpha")])
        a = tab(c, @surface)
        o = page_owners(a)
        b_saves(c, a, [empty_it(), it("alpha")])
        q = drain(a)
        owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

        autosave(a, ["<p>a1</p>", "<p>alpha</p>"], owners, @seen, q)

        assert items_words(stored(c)) == [["a1"], ["alpha"]],
               "A's post on B's value was held: #{inspect(items_words(stored(c)))}"

        assert held(a) == []
      end
    end

    test "#{@tag_name} AF: B adds an empty row in front; A (stale alpha) types in row 0: held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [empty_it(), it("alpha")])
      q = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      autosave(
        a,
        ["<p>alpha</p><p>new A</p>", "<p>alpha</p>"],
        owners,
        @seen,
        Map.take(q, [@row1])
      )

      # B's empty row is kept (an empty rich text reads as nil or []).
      assert [first, ["alpha"]] = items_words(stored(c))
      assert first in [nil, []]
      assert held(a) != []
    end

    # Controls: no move, written as on main.

    test "#{@tag_name} control T2c: B edits row 1 twice in place; A types in row 0: written", c do
      put_items(c, [it("alpha"), it("beta")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("alpha"), it("beta B")])
      b_saves(c, a, [it("alpha"), it("beta BB")])
      q = drain(a)

      autosave(a, ["<p>alpha A</p>", "<p>beta BB</p>"], o, @seen, Map.take(q, [@row1]))

      assert items_words(stored(c)) == [["alpha A"], ["beta BB"]]
      assert held(a) == []
    end

    # FH2's shape by two saves: B's edit of row 0 and B's copy of its old
    # text are two saves, so no save moved row 0's draw.

    test "#{@tag_name} control E1: [empty]; A types; B adds an empty row; A types more in row 0: written",
         c do
      put_items(c, [empty_it()])
      a = tab(c, @surface)
      o = page_owners(a)
      autosave(a, ["<p>a1</p>"], o, @seen)
      b_saves(c, a, [itk("a1"), empty_it()])
      b_saves(c, a, [itk("a1"), itk("b1")])
      q = drain(a)
      owners = o ++ [entry(1, [], own(o, 0))]

      autosave(a, ["<p>a1 a2</p>", "<p>b1</p>"], owners, @seen, Map.take(q, [@row1]))

      assert items_words(stored(c)) == [["a1 a2"], ["b1"]]
      assert held(a) == []
    end
  end
end
