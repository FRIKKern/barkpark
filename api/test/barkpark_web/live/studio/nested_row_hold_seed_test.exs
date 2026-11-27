defmodule BarkparkWeb.Studio.NestedRowHoldSeedTest do
  @moduledoc """
  task-38e3de7fb9f10312 (#29223 review: H1, H2, G8). While A has a row
  rich text held in place, A's form is unsaved and stops taking B's saves
  of that field. A stale post seeded the array from that frozen form, so
  the save wrote A's old rows back: B's inserted row lost (H1), B's
  removed row back (H2), A's held view written by a post that did not
  carry it (G8). While a hold is open the array is seeded from the store,
  with only the leaves the post carries over it.
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

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp two, do: [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])]
  defp stale, do: [{"s1", [{"i1", "<p>alpha A</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}]

  # B edits i1, A's stale page types in it: a clash, A held in place.
  defp held_in_place(c, surface) do
    put_doc(c, two())
    a = tab(c, surface)
    owners = page_owners(a)
    b_saves(c, a, [sec("s1", [it("i1", "alpha B")]), sec("s2", [it("i2", "beta")])])
    autosave(a, stale(), owners)
    assert held(a) == ["doc[sections][0].items[0].rt"], "A was not held: no test"
    {a, owners}
  end

  # B's save while A's form is held: the form keeps A's rows, so wait for
  # the socket to hear it.
  defp b_saves_under_hold(c, a, sections, word) do
    put_doc(c, sections)

    assert eventually(fn ->
             inspect(:sys.get_state(a.pid).socket.assigns,
               limit: :infinity,
               printable_limit: :infinity
             ) =~
               word
           end),
           "A's socket did not hear B's save: no test"
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} H1: A held in place; B inserts a row before it; A's stale page posts: B's row kept",
         c do
      {a, owners} = held_in_place(c, @surface)

      b =
        [sec("s1", [it("i0", "zero"), it("i1", "alpha B")]), sec("s2", [it("i2", "beta")])]

      b_saves_under_hold(c, a, b, "zero")

      autosave(a, stale(), owners)

      assert shape(stored(c)) == [
               {"s1", [{"i0", ["zero"]}, {"i1", ["alpha B"]}]},
               {"s2", [{"i2", ["beta"]}]}
             ],
             "B's insert was lost or A's held words written: #{inspect(shape(stored(c)))}"
    end

    test "#{surface} H2: A held in place; B removes the held row; A's stale posts: the row stays removed",
         c do
      {a, owners} = held_in_place(c, @surface)
      b_saves_under_hold(c, a, [sec("s1", []), sec("s2", [it("i2", "beta X")])], "beta X")

      autosave(a, stale(), owners)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta X"]}]}],
             "B's removed row came back: #{inspect(shape(stored(c)))}"

      autosave(a, [{"s1", []}, {"s2", [{"i2", "<p>beta X</p>"}]}], owners)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta X"]}]}],
             "B's removed row came back: #{inspect(shape(stored(c)))}"
    end

    test "#{surface} G8: A held in place; a post without the held row: the held view never written",
         c do
      {a, owners} = held_in_place(c, @surface)

      autosave(a, [{"s1", []}, {"s2", [{"i2", "<p>beta A</p>"}]}], owners)

      assert shape(stored(c)) == [{"s1", [{"i1", ["alpha B"]}]}, {"s2", [{"i2", ["beta A"]}]}],
             "A's held view was written: #{inspect(shape(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
    end

    test "#{surface} control: A held in place adds a row and types in it: A's row written", c do
      {a, owners} = held_in_place(c, @surface)

      BarkparkWeb.EditorPost.press(a, "array_op", %{
        "action" => "add_row",
        "field" => "items",
        "path" => "doc[sections][1].items",
        "member" => "item"
      })

      new = get_in(form(a), ["sections", Access.at(1), "items", Access.at(1), "_key"])
      assert is_binary(new), "add_row made no keyed row: no test"

      autosave(
        a,
        [
          {"s1", [{"i1", "<p>alpha A</p>"}]},
          {"s2", [{"i2", "<p>beta</p>"}, {new, "<p>new A</p>"}]}
        ],
        owners
      )

      assert Map.new(shape(stored(c)))["s2"] == [{"i2", ["beta"]}, {new, ["new A"]}],
             "A's new row was lost: #{inspect(shape(stored(c)))}"
    end
  end
end
