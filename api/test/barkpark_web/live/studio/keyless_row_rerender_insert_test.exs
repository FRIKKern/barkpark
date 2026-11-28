defmodule BarkparkWeb.Studio.KeylessRowRerenderInsertTest do
  @moduledoc """
  task-8d968bba2cfa23c4 (#29178 r2 review, R2r). B puts a keyless row in
  before A's. A's page re-renders: the editor at index 0 sits in an
  ignored wrapper and keeps A's draw, and the new index 1 draws the same
  value. The post's indexes match the form's, so `KeylessShift` saw no
  move, and A's words were merged into B's row by index with no banner.
  Two rows of one text (D1-D5) post the same shape, and must merge: what
  differs is when the socket first had the draw at the other index.
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

  defp array(name, of), do: %{"name" => name, "title" => name, "type" => "arrayOf", "of" => [of]}

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
    test "#{@tag_name} control J2R: J2 held, Reload, A types in row 0: written with seen, held without",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])
      autosave(a, ["<p>alpha</p><p>new A</p>"], o, @seen)
      assert held(a) != []
      render_hook(a, "reload-remote-doc", %{})
      q = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]
      autosave(a, ["<p>zed B</p><p>new A</p>", "<p>alpha</p>"], owners, @seen, q)
      reloaded(c, a, @seen)
    end

    test "#{@tag_name} control J7: B edits row 1, A row 0: merged", c do
      put_items(c, [it("alpha"), it("beta")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("alpha"), it("beta B")])
      autosave(a, ["<p>alpha A</p>", "<p>beta</p>"], o, @seen)
      assert items_words(stored(c)) == [["alpha A"], ["beta B"]]
      assert held(a) == []
    end

    test "#{@tag_name} control Q7: B edits block 2 of row 0, A block 1: merged", c do
      put_items(c, [itk2("alpha", "omega")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [itk2("alpha", "omega B")])
      autosave(a, ["<p>alpha A</p><p>omega</p>"], o, @seen)
      assert items_words(stored(c)) == [["alpha A", "omega B"]]
      assert held(a) == []
    end

    test "#{@tag_name} control D1: two rows of one text, A types in row 0 twice: written", c do
      put_items(c, [itk("same"), itk("same")])
      a = tab(c, @surface)
      o = page_owners(a)
      autosave(a, ["<p>same A</p>", "<p>same</p>"], o, @seen)
      html = autosave(a, ["<p>same AA</p>", "<p>same</p>"], o, @seen)
      assert items_words(stored(c)) == [["same AA"], ["same"]]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{@tag_name} control D2: two empty rows, A types in row 0 twice: written", c do
      put_items(c, [empty_it(), empty_it()])
      a = tab(c, @surface)
      o = page_owners(a)
      autosave(a, ["<p>x</p>", ""], o, @seen)
      autosave(a, ["<p>xy</p>", ""], o, @seen)
      assert hd(items_words(stored(c))) == ["xy"]
      assert held(a) == []
    end

    test "#{@tag_name} control D3: two rows of one text, B edits row 0 in place, A row 1: merged",
         c do
      put_items(c, [itk2("same", "tail"), itk2("same", "tail")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [itk2("same", "tail B"), itk2("same", "tail")])
      autosave(a, ["<p>same</p><p>tail</p>", "<p>same A</p><p>tail</p>"], o, @seen)
      assert items_words(stored(c)) == [["same", "tail B"], ["same A", "tail"]]
      assert held(a) == []
    end

    test "#{@tag_name} control D4: two rows of one text, B and A edit row 0's blocks: merged",
         c do
      put_items(c, [itk2("same", "tail"), itk2("same", "tail")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [itk2("same", "tail B"), itk2("same", "tail")])
      autosave(a, ["<p>same A</p><p>tail</p>", "<p>same</p><p>tail</p>"], o, @seen)
      assert items_words(stored(c)) == [["same A", "tail B"], ["same", "tail"]]
      assert held(a) == []
    end

    test "#{@tag_name} control D5: two empty rows, B types in row 0, A in row 1: both kept", c do
      put_items(c, [empty_it(), empty_it()])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [itk("b words"), empty_it()])
      autosave(a, ["", "<p>a words</p>"], o, @seen)
      assert items_words(stored(c)) == [["b words"], ["a words"]]
      assert held(a) == []
    end

    test "#{@tag_name} control: A types row 1 into row 0's first text, then types in row 0 again: written",
         c do
      put_items(c, [it("alpha"), it("beta")])
      a = tab(c, @surface)
      o = page_owners(a)
      autosave(a, ["<p>alpha A</p>", "<p>beta</p>"], o, @seen)
      autosave(a, ["<p>alpha A</p>", "<p>alpha</p>"], o, @seen)
      b_saves(c, a, [it("alpha A"), it("alpha"), it("gamma B")])
      owners = o ++ [entry(2, it("gamma B")["rt"], own(o, 0))]

      html = autosave(a, ["<p>alpha AA</p>", "<p>alpha</p>", "<p>gamma B</p>"], owners, @seen)

      assert items_words(stored(c)) == [["alpha AA"], ["alpha"], ["gamma B"]]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    # #29315 review, false holds: row i changed by A's own typing while row
    # j took row i's draw from B (E1-E3), a Reload (RL1, RL2), and A typing
    # only in the re-rendered row (P2).
    @row1 "doc[sections][0].items[1].rt"

    test "#{@tag_name} E1: [empty]; A types; B adds an empty row; A types more in row 0: written",
         c do
      put_items(c, [empty_it()])
      a = tab(c, @surface)
      o = page_owners(a)
      autosave(a, ["<p>a1</p>"], o, @seen)
      b_saves(c, a, [itk("a1"), empty_it()])
      q = drain(a)
      owners = o ++ [entry(1, [], own(o, 0))]

      html = autosave(a, ["<p>a1 a2</p>", ""], owners, @seen, Map.take(q, [@row1]))

      assert items_words(stored(c)) == [["a1 a2"], []]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{@tag_name} E2: [empty, beta]; A types in row 0; B clears row 1; A types more: written",
         c do
      put_items(c, [empty_it(), it("beta")])
      a = tab(c, @surface)
      o = page_owners(a)
      autosave(a, ["<p>a1</p>", "<p>beta</p>"], o, @seen)
      b_saves(c, a, [itk("a1"), empty_it()])
      q = drain(a)

      autosave(a, ["<p>a1 a2</p>", ""], o, @seen, Map.take(q, [@row1]))

      assert items_words(stored(c)) == [["a1 a2"], []]
      assert held(a) == []
    end

    test "#{@tag_name} E3: A types in row 0; B sets row 1 to row 0's first text; A types more: written",
         c do
      put_items(c, [itk("alpha"), itk("beta")])
      a = tab(c, @surface)
      o = page_owners(a)
      autosave(a, ["<p>alpha A</p>", "<p>beta</p>"], o, @seen)
      b_saves(c, a, [itk("alpha A"), itk("alpha")])
      q = drain(a)

      autosave(a, ["<p>alpha AA</p>", "<p>alpha</p>"], o, @seen, Map.take(q, [@row1]))

      assert items_words(stored(c)) == [["alpha AA"], ["alpha"]]
      assert held(a) == []
    end

    test "#{@tag_name} RL1: R2r page; A presses Reload; A types in row 0, which shows B's row: written",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])
      _ = drain(a)
      render_hook(a, "reload-remote-doc", %{})
      q = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      autosave(a, ["<p>zed B</p><p>new A</p>", "<p>alpha</p>"], owners, @seen, q)

      assert items_words(stored(c)) == [["zed B", "new A"], ["alpha"]]
      assert held(a) == []
    end

    test "#{@tag_name} RL2: R2r held; A presses Reload; A types again in row 0: written", c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])
      q0 = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      autosave(
        a,
        ["<p>alpha</p><p>new A</p>", "<p>alpha</p>"],
        owners,
        @seen,
        Map.take(q0, [@row1])
      )

      assert held(a) != []
      render_hook(a, "reload-remote-doc", %{})
      q = drain(a)

      autosave(a, ["<p>zed B</p><p>new A</p>", "<p>alpha</p>"], owners, @seen, q)

      # The R2r history plays no part after the Reload: as J2R.
      reloaded(c, a, @seen)
    end

    test "#{@tag_name} control RL3: Reload, then B inserts in front; A types in row 0: held", c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      render_hook(a, "reload-remote-doc", %{})
      _ = drain(a)
      b_saves(c, a, [it("zed B"), it("alpha")])
      q = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      autosave(
        a,
        ["<p>alpha</p><p>new A</p>", "<p>alpha</p>"],
        owners,
        @seen,
        Map.take(q, [@row1])
      )

      assert items_words(stored(c)) == [["zed B"], ["alpha"]]
      assert held(a) != []
    end

    test "#{@tag_name} P2: R2r page; A types only in the re-rendered row 1: written", c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])
      q = drain(a)
      owners = [own(o, 0), entry(1, it("alpha")["rt"], own(o, 0))]

      autosave(a, ["<p>alpha</p>", "<p>alpha A</p>"], owners, @seen, Map.take(q, [@row1]))

      assert items_words(stored(c)) == [["zed B"], ["alpha A"]]
      assert held(a) == []
    end
  end
end
