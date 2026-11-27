defmodule BarkparkWeb.Studio.NestedRowKeylessTest do
  @moduledoc """
  task-f10341a15bcac784 (#29164 review, E7b). Rows with no `_key` go by
  their index. B inserts a keyless item before A's; A's post, typed on the
  first draw, names A's item by its old index, and the fold writes it into
  the item now there, B's. `UnderLock` read that row's draw by index, but
  `ObjectRebase` rebased only rows with a `_key`, so A's text was written
  over B's new item with no banner. A keyless row is now read against the
  keyless row at its index: merged, or the store's kept and A held.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live
  @rb "Someone else rewrote"

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

  # A's post as its page sends it: the items' HTML by the index the page
  # drew them at.
  defp autosave(a, htmls, owners) do
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

    render_hook(a, "autosave", params)
  end

  # Rows whose blocks share keys, as `from_html` makes them (#29178 review).
  defp itk(text), do: %{"_type" => "item", "rt" => [block("b0", text)]}
  defp itk2(t1, t2), do: %{"_type" => "item", "rt" => [block("b0", t1), block("b1", t2)]}

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} E7b: B inserts a keyless item before A's; A's old page types in it: B kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])

      html = autosave(a, ["<p>alpha A</p>"], owners)

      # Before: [["alpha A"], ["alpha"]], B's "zed B" lost, no banner.
      assert items_words(stored(c)) == [["zed B"], ["alpha"]],
             "A's post was written over B's new item: #{inspect(items_words(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} E7: B edits one keyless item, A's old page types in the other: merged", c do
      put_items(c, [it("alpha"), it("beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("alpha"), it("beta B")])

      html = autosave(a, ["<p>alpha A</p>", "<p>beta</p>"], owners)

      assert items_words(stored(c)) == [["alpha A"], ["beta B"]],
             "not merged: #{inspect(items_words(stored(c)))}"

      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} control: A alone types in a keyless item: written", c do
      put_items(c, [it("alpha"), it("beta")])
      a = tab(c, @surface)

      html = autosave(a, ["<p>alpha A</p>", "<p>beta</p>"], page_owners(a))

      assert items_words(stored(c)) == [["alpha A"], ["beta"]]
      assert held(a) == []
      refute html =~ @rb
    end

    # #29178 review: with a keyless row inserted or removed before A's, the
    # index names another row. A's edit that did not clash with that row's
    # blocks was merged into it, with no banner. It is now read as a draw
    # not known: the store kept, A held.
    test "#{surface} Q2: B inserts a keyless row before A's; A adds a paragraph: B's row kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])

      html = autosave(a, ["<p>alpha</p><p>new A</p>"], owners)

      assert items_words(stored(c)) == [["zed B"], ["alpha"]],
             "A's words were merged into B's row: #{inspect(items_words(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} Q2, A's stale page posts again: B's row still kept, A still held", c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])

      autosave(a, ["<p>alpha</p><p>new A</p>"], owners)
      html = autosave(a, ["<p>alpha</p><p>new A</p><p>more A</p>"], owners)

      assert items_words(stored(c)) == [["zed B"], ["alpha"]],
             "A's second post was written: #{inspect(items_words(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} Q2t: B inserts a two-block row before A's; A edits its second block: B's row kept, A held",
         c do
      put_items(c, [itk2("alpha", "omega")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [itk2("zed B", "omega"), itk2("alpha", "omega")])

      html = autosave(a, ["<p>alpha</p><p>omega A</p>"], owners)

      assert items_words(stored(c)) == [["zed B", "omega"], ["alpha", "omega"]],
             "A's words were merged into B's row: #{inspect(items_words(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} Q4c: B removes keyless row 0; A adds a paragraph to it: the row now first kept, A held",
         c do
      put_items(c, [itk("alpha"), itk("beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [itk("beta")])

      html = autosave(a, ["<p>alpha</p><p>new A</p>", "<p>beta</p>"], owners)

      assert hd(items_words(stored(c))) == ["beta"],
             "A's words were merged into the row now first: #{inspect(items_words(stored(c)))}"

      assert "doc[sections][0].items[0].rt" in held(a)
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} Q7: B edits one block of a keyless row, A another: merged", c do
      put_items(c, [itk2("alpha", "omega")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [itk2("alpha", "omega B")])

      html = autosave(a, ["<p>alpha A</p><p>omega</p>"], owners)

      assert items_words(stored(c)) == [["alpha A", "omega B"]]
      assert held(a) == []
      refute html =~ @rb
    end
  end
end
