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
  # page drew them at, with its owner entries.
  defp autosave(a, htmls, owners, seen) do
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
            for(i <- 0..(length(htmls) - 1), do: "doc[sections][0].items[#{i}].rt|0")
          ),
        else: params

    render_hook(a, "autosave", params)
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
  end
end
