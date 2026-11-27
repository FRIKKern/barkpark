defmodule BarkparkWeb.Studio.NestedRowKeylessSeenTest do
  @moduledoc """
  task-7085fe2cc12fb328 (#29178 review, round 2: J2, J2t, J4c and R2r).
  Rows with no `_key` go by their index. B puts a keyless row in before
  A's, or takes one out; A's stale page posts. #29178 read such a post as
  a draw not known only with no `_bp_rt_seen`, by the indexes of the
  keyless rows the page drew. A page with bp-rt-remote.js posts
  `_bp_rt_seen`, and `RichTextRemote.split/3` merged A's words by name,
  so by index, into B's row with no banner (J2-J4c). A page re-rendered
  after B's insert drew an entry at every index, the first still with
  A's draw, so the indexes matched (R2r). A list whose keyless rows moved
  is now found on both paths, also by a draw that sits at another index
  in the form: the store is kept and A held. B's edit of a row in place
  still merges (J7, Q7).
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
  defp autosave(a, htmls, owners, seen \\ nil) do
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

    params = if seen, do: Map.put(params, "_bp_rt_seen", seen), else: params
    render_hook(a, "autosave", params)
  end

  # Rows whose blocks share keys, as `from_html` makes them (#29178 review).
  defp itk(text), do: %{"_type" => "item", "rt" => [block("b0", text)]}
  defp itk2(t1, t2), do: %{"_type" => "item", "rt" => [block("b0", t1), block("b1", t2)]}

  # The numbers a page with bp-rt-remote.js posts before any push: 0.
  defp seen0(n), do: for(i <- 0..(n - 1), do: "doc[sections][0].items[#{i}].rt|0")

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} J2: B inserts a keyless row before A's; A's page with seen adds a paragraph: B's row kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])

      html = autosave(a, ["<p>alpha</p><p>new A</p>"], owners, seen0(1))

      assert items_words(stored(c)) == [["zed B"], ["alpha"]],
             "A's words were merged into B's row: #{inspect(items_words(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} J2t: B inserts a two-block row before A's; A's page with seen edits its second block: B's row kept, A held",
         c do
      put_items(c, [itk2("alpha", "omega")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [itk2("zed B", "omega"), itk2("alpha", "omega")])

      html = autosave(a, ["<p>alpha</p><p>omega A</p>"], owners, seen0(1))

      assert items_words(stored(c)) == [["zed B", "omega"], ["alpha", "omega"]],
             "A's words were merged into B's row: #{inspect(items_words(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} J4c: B removes keyless row 0; A's page with seen adds a paragraph to it: the row now first kept, A held",
         c do
      put_items(c, [itk("alpha"), itk("beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [itk("beta")])

      html = autosave(a, ["<p>alpha</p><p>new A</p>", "<p>beta</p>"], owners, seen0(2))

      assert hd(items_words(stored(c))) == ["beta"],
             "A's words were merged into the row now first: #{inspect(items_words(stored(c)))}"

      assert "doc[sections][0].items[0].rt" in held(a)
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} R2r: B inserts a keyless row; A's page re-rendered, no seen, adds a paragraph: B's row kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      b_saves(c, a, [it("zed B"), it("alpha")])
      # Read after the re-render: an entry at each index, the first still
      # with alpha's draw (its editor sits in an ignored wrapper).
      owners = page_owners(a)
      assert length(owners) == 2, "the page did not draw both rows: no test"

      html = autosave(a, ["<p>alpha</p><p>new A</p>", "<p>alpha</p>"], owners)

      assert items_words(stored(c)) == [["zed B"], ["alpha"]],
             "A's words were merged into B's row: #{inspect(items_words(stored(c)))}"

      assert "doc[sections][0].items[0].rt" in held(a)
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} J7: B edits keyless row 1, A's page with seen types in row 0: merged", c do
      put_items(c, [it("alpha"), it("beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("alpha"), it("beta B")])

      html = autosave(a, ["<p>alpha A</p>", "<p>beta</p>"], owners, seen0(2))

      assert items_words(stored(c)) == [["alpha A"], ["beta B"]]
      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} Q7 with seen: B edits one block of a keyless row, A another: merged", c do
      put_items(c, [itk2("alpha", "omega")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [itk2("alpha", "omega B")])

      html = autosave(a, ["<p>alpha A</p><p>omega</p>"], owners, seen0(1))

      assert items_words(stored(c)) == [["alpha A", "omega B"]]
      assert held(a) == []
      refute html =~ @rb
    end
  end
end
