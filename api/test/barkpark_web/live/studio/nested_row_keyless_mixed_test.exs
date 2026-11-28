defmodule BarkparkWeb.Studio.NestedRowKeylessMixedTest do
  @moduledoc """
  task-4d6529dace20f151 (#29178 r2 review, M3). A list holds a keyless row
  and a keyed one. B inserts a keyed row in front of the keyless row; A's
  page, typed on the first draw, posts the keyless row at its old index,
  where B's keyed row now is.
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

  # A's post as its page sends it: each item's HTML, and its `_key` when it
  # has one, by the index the page drew it at.
  defp autosave(a, htmls, owners, target, seen \\ nil) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params =
      htmls
      |> Enum.with_index()
      |> Enum.flat_map(fn {{html, key}, i} ->
        [
          {"doc[sections][0].items[#{i}]._type", "item"},
          {"doc[sections][0].items[#{i}].rt", html}
        ] ++ if(key, do: [{"doc[sections][0].items[#{i}]._key", key}], else: [])
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
        "_target" => [target],
        "_bp_rt_owner" => owners
      })

    # A page with bp-rt-remote.js also posts `_bp_rt_seen[]`: 0 before any push.
    params = if seen, do: Map.put(params, "_bp_rt_seen", seen), else: params
    render_hook(a, "autosave", params)
  end

  defp keyed(k, text), do: %{"_type" => "item", "_key" => k, "rt" => [block("k" <> text, text)]}
  defp items_keys(content), do: Enum.map(hd(content["sections"])["items"], & &1["_key"])
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  @row0 "doc[sections][0].items[0].rt"
  @row1 "doc[sections][0].items[1].rt"

  for surface <- [:desk, :studio] do
    @surface surface

    for seen <- [false, true] do
      @seen seen
      test "#{surface} M3#{if seen, do: " (with _bp_rt_seen)"}: B inserts a keyed row in front of the keyless one; A types in the keyless: B's row kept, A held",
           c do
        put_items(c, [it("alpha"), keyed("k1", "one")])
        a = tab(c, @surface)
        owners = page_owners(a)
        b_saves(c, a, [keyed("k0", "zero B"), it("alpha"), keyed("k1", "one")])

        html =
          autosave(
            a,
            [{"<p>alpha</p><p>new A</p>", nil}, {"<p>one</p>", "k1"}],
            owners,
            @row0,
            if(@seen, do: ["#{@row0}|0", "#{@row1}|0"])
          )

        # Before, with no seen: A's keyless post written into k0, B's "zero B"
        # lost, no banner. With a seen it was already held (`split/4`).
        assert items_words(stored(c)) == [["zero B"], ["alpha"], ["one"]],
               "A's keyless post was written into B's row: #{inspect(items_words(stored(c)))}"

        assert items_keys(stored(c)) == ["k0", nil, "k1"]
        assert held(a) != []
        assert html =~ "doc-conflict-banner"
      end
    end

    test "#{surface} M1 control: a mixed list, A alone types in the keyed row, then the keyless: written",
         c do
      put_items(c, [keyed("k1", "one"), it("alpha")])
      a = tab(c, @surface)
      autosave(a, [{"<p>one A</p>", "k1"}, {"<p>alpha</p>", nil}], page_owners(a), @row0)

      html =
        autosave(a, [{"<p>one A</p>", "k1"}, {"<p>alpha A</p>", nil}], page_owners(a), @row1)

      assert items_words(stored(c)) == [["one A"], ["alpha A"]]
      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} M2 control: a mixed list, B edits keyed k1, A types in the keyless: merged",
         c do
      put_items(c, [keyed("k1", "one"), it("alpha")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [%{keyed("k1", "one") | "rt" => [block("kone", "one B")]}, it("alpha")])
      html = autosave(a, [{"<p>one</p>", "k1"}, {"<p>alpha A</p>", nil}], owners, @row1)
      assert items_words(stored(c)) == [["one B"], ["alpha A"]]
      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} M3 control: B inserts a keyed row at the end; A types in the keyless: written",
         c do
      put_items(c, [it("alpha"), keyed("k1", "one")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("alpha"), keyed("k1", "one"), keyed("k2", "two B")])

      html =
        autosave(a, [{"<p>alpha</p><p>new A</p>", nil}, {"<p>one</p>", "k1"}], owners, @row0)

      assert items_words(stored(c)) == [["alpha", "new A"], ["one"], ["two B"]]
      assert held(a) == []
      refute html =~ @rb
    end
  end
end
