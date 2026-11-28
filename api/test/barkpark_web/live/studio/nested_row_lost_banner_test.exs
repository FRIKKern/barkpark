defmodule BarkparkWeb.Studio.NestedRowLostBannerTest do
  @moduledoc """
  task-3fa8e35f0147034c (#29223 r2 review, B3 and B6). A row rich text the
  fold cannot place is shown in the banner as A's words (`DroppedRows`).

  - B3: A types in a row and removes it with its own remove_row; a post the
    page sent before it redrew arrives. The banner blamed another editor
    who did nothing.
  - B6: a later post or Save cleared `doc_conflict` and hid the banner, but
    the `{:lost, _}` entry stayed in `editor_rt_clash`, so a later,
    unrelated clash showed the old "moved or removed" line again.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
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

  defp it(key, text), do: %{"_type" => "item", "_key" => key, "rt" => [block(key <> text, text)]}
  defp sec(key, items), do: %{"_type" => "section", "_key" => key, "items" => items}
  defp lst(l) when is_list(l), do: l
  defp lst(_), do: []

  defp put_c(c, content) do
    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "T0", "content" => content},
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

  defp shape(content) do
    for s <- lst(content["sections"]),
        do: {s["_key"], Enum.map(lst(s["items"]), &{&1["_key"], words(&1["rt"])})}
  end

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  defp b_saves(c, a, content) do
    put_c(c, content)
    want = shape(content)
    assert eventually(fn -> shape(form(a)) == want end), "A's socket did not take B's save"
  end

  defp params(a, sections, owners) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    sections
    |> Enum.with_index()
    |> Enum.flat_map(fn {{skey, items}, i} ->
      [{"doc[sections][#{i}]._type", "section"}, {"doc[sections][#{i}]._key", skey}] ++
        (items
         |> Enum.with_index()
         |> Enum.flat_map(fn {{ikey, html}, j} ->
           p = "doc[sections][#{i}].items[#{j}]"
           [{p <> "._type", "item"}, {p <> "._key", ikey}, {p <> ".rt", html}]
         end))
    end)
    |> Map.new()
    |> Map.put("doc[title]", "T0")
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
    |> Map.merge(%{
      "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id),
      "_target" => ["doc[sections][0].items[0].rt"],
      "_bp_rt_owner" => owners
    })
  end

  defp autosave(a, sections, owners), do: render_hook(a, "autosave", params(a, sections, owners))

  defp save(a, sections, owners),
    do:
      a
      |> element("#editor-form")
      |> render_submit(params(a, sections, owners) |> Map.delete("_target"))

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp lost(a),
    do:
      for(
        {{:lost, n}, t} <- :sys.get_state(a.pid).socket.assigns[:editor_rt_clash] || %{},
        do: {n, t}
      )

  defp two, do: [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])]
  defp removed_s, do: [sec("s1", []), sec("s2", [it("i2", "beta")])]
  defp stale, do: [{"s1", [{"i1", "<p>alpha A</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}]

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} B3: A types in i1, removes it itself, then a post sent before the redraw: no banner",
         c do
      put_c(c, %{"sections" => two()})
      a = tab(c, @surface)
      o = page_owners(a)
      autosave(a, stale(), o)

      BarkparkWeb.EditorPost.press(a, "array_op", %{
        "action" => "remove_row",
        "path" => "doc[sections][0].items",
        "index" => "0"
      })

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}]}]

      html = autosave(a, stale(), o)

      # On #29223: the banner says another editor moved or removed the row.
      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}]}]
      assert lost(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: B removes the row A typed in: A's words shown", c do
      put_c(c, %{"sections" => two()})
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, %{"sections" => removed_s()})

      html = autosave(a, stale(), o)

      assert lost(a) == [{"doc[sections][0].items[0].rt", ["alpha A"]}]
      assert html =~ "doc-conflict-lost"
    end

    test "#{surface} B6: after a post and a Save end the banner, an unrelated clash shows no old lost words",
         c do
      put_c(c, %{"sections" => two()})
      a = tab(c, @surface)
      o = page_owners(a)
      b_saves(c, a, %{"sections" => removed_s()})
      autosave(a, stale(), o)
      assert lost(a) != []

      autosave(a, [{"s1", []}, {"s2", [{"i2", "<p>beta A</p>"}]}], page_owners(a))
      assert lost(a) == []

      html =
        autosave(
          a,
          [{"s1", [{"i1", "<p>alpha A more</p>"}]}, {"s2", [{"i2", "<p>beta A</p>"}]}],
          o
        )

      assert lost(a) == [{"doc[sections][0].items[0].rt", ["alpha A more"]}]
      assert html =~ "doc-conflict-lost"

      save(a, [{"s1", []}, {"s2", [{"i2", "<p>beta A</p>"}]}], page_owners(a))
      assert lost(a) == []

      o3 = page_owners(a)
      b_saves(c, a, %{"sections" => [sec("s1", []), sec("s2", [it("i2", "beta B")])]})
      html = autosave(a, [{"s1", []}, {"s2", [{"i2", "<p>beta A2</p>"}]}], o3)

      # On #29223: the banner shows "alpha A more" with the moved-or-removed line.
      assert held(a) == ["doc[sections][1].items[0].rt"]
      assert html =~ "doc-conflict-banner"
      refute html =~ "doc-conflict-lost"
      refute html =~ "alpha A more"
      assert lost(a) == []
    end
  end
end
