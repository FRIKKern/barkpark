defmodule BarkparkWeb.Studio.NestedRowMovedRepostTest do
  @moduledoc """
  task-3422ba9e403f8b75, #29180 and #29223 reviews. A's words typed in a
  row another editor moved under another parent are shown in the banner,
  never written there and never held. A hold at the moved row froze A's
  form, so A's next stale post wrote the old rows back over B's later
  change: B's removal undone (G3), B's new row lost (G3b, G4), B's move
  undone (G4b), B's second save lost (F4), A's words written into a
  Duplicate copy (F8). Each now keeps B's change, as main does, and the
  banner still shows A's words.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live
  @lost "Your text was in a row another editor moved or removed. Copy it before you reload."

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

  defp it(key, text),
    do: %{"_type" => "item", "_key" => key, "rt" => [block(key <> text, text)]}

  defp sec(key, items), do: %{"_type" => "section", "_key" => key, "items" => items}

  defp put_doc(c, sections) do
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

  # Each section's items, `{key, words}`.
  defp shape(content) do
    for s <- content["sections"] || [],
        do: {s["_key"], Enum.map(s["items"] || [], &{&1["_key"], words(&1["rt"])})}
  end

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  defp b_saves(c, a, sections) do
    put_doc(c, sections)
    want = shape(%{"sections" => sections})

    assert eventually(fn -> shape(form(a)) == want end),
           "A's socket did not take B's save: no test"
  end

  # A's post as its page sends it: `[{section key, [{item key, html}]}]` by
  # the indexes the page drew them at.
  defp autosave(a, sections, owners),
    do: render_hook(a, "autosave", post_params(a, sections, owners))

  defp post_params(a, sections, owners) do
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

  # A's words the banner shows as A's.
  defp mine(view) do
    ~r/<blockquote[^>]*data-version="mine"[^>]*>(.*?)<\/blockquote>/s
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, text] -> String.trim(text) end)
  end

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp two, do: [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])]
  defp moved, do: [sec("s1", []), sec("s2", [it("i2", "beta"), it("i1", "alpha")])]
  defp copied, do: [sec("s1", []), sec("s1x", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])]
  defp stale, do: [{"s1", [{"i1", "<p>alpha A</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}]

  # A types in i1, B moves it into s2, A's stale page posts: the banner.
  defp moved_banner(c, surface) do
    put_doc(c, two())
    a = tab(c, surface)
    owners = page_owners(a)
    b_saves(c, a, moved())
    html = autosave(a, stale(), owners)
    assert html =~ @lost, "A's words were not in the banner: no test"
    {a, owners}
  end

  defp banner_shows_a(a, html) do
    assert html =~ @lost
    assert mine(a) == ["alpha A"]
    assert held(a) == []
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} F1.1: A's stale page posts again: nothing written, the banner still shows A's words",
         c do
      {a, owners} = moved_banner(c, @surface)

      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == shape(%{"sections" => moved()}),
             "A's words were written: #{inspect(shape(stored(c)))}"

      banner_shows_a(a, html)
    end

    test "#{surface} G3: B then removes i1; A's stale page posts twice: B's removal kept", c do
      {a, owners} = moved_banner(c, @surface)
      b_saves(c, a, [sec("s1", []), sec("s2", [it("i2", "beta")])])

      autosave(a, stale(), owners)
      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}]}],
             "B's removal was undone: #{inspect(shape(stored(c)))}"

      banner_shows_a(a, html)
    end

    test "#{surface} G3b: B then removes i1 and adds i9; A's stale page posts: i9 kept", c do
      {a, owners} = moved_banner(c, @surface)
      b_saves(c, a, [sec("s1", []), sec("s2", [it("i2", "beta"), it("i9", "nine")])])

      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i9", ["nine"]}]}],
             "B's new row was lost: #{inspect(shape(stored(c)))}"

      banner_shows_a(a, html)
    end

    test "#{surface} G4: B then inserts i0 before i2; A's stale page posts twice: every row kept",
         c do
      {a, owners} = moved_banner(c, @surface)

      b_saves(c, a, [
        sec("s1", []),
        sec("s2", [it("i0", "zero"), it("i2", "beta"), it("i1", "alpha")])
      ])

      autosave(a, stale(), owners)
      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == [
               {"s1", []},
               {"s2", [{"i0", ["zero"]}, {"i2", ["beta"]}, {"i1", ["alpha"]}]}
             ],
             "B's insert was lost: #{inspect(shape(stored(c)))}"

      banner_shows_a(a, html)
    end

    test "#{surface} G4b: B then moves i1 back to s1; A's stale page posts: B's move kept, A's edit in place",
         c do
      {a, owners} = moved_banner(c, @surface)
      b_saves(c, a, two())

      autosave(a, stale(), owners)

      assert shape(stored(c)) == [{"s1", [{"i1", ["alpha A"]}]}, {"s2", [{"i2", ["beta"]}]}],
             "B's move was undone: #{inspect(shape(stored(c)))}"
    end

    test "#{surface} F4: B then saves i1 again; A's stale page posts: B's second save kept", c do
      {a, owners} = moved_banner(c, @surface)
      b_saves(c, a, [sec("s1", []), sec("s2", [it("i2", "beta"), it("i1", "alpha B2")])])

      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha B2"]}]}],
             "B's second save was lost: #{inspect(shape(stored(c)))}"

      banner_shows_a(a, html)
    end

    test "#{surface} F8: B duplicates s1 and removes the original i1; A's stale page posts twice: the copy kept",
         c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, copied())

      autosave(a, stale(), owners)
      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == shape(%{"sections" => copied()}),
             "A's words were written into the copy: #{inspect(shape(stored(c)))}"

      banner_shows_a(a, html)
    end
  end
end
