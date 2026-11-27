defmodule BarkparkWeb.Studio.NestedRowMovedTest do
  @moduledoc """
  task-3422ba9e403f8b75 (#29164 review, E13). B moves item i1 from section
  s1 to s2; A's page, not yet redrawn, types in i1 under s1. The fold
  (`Fields.row_path/4`) found no i1 in s1 and dropped A's words with no
  banner. The one row of that field shape that holds i1 now gets A's words
  as a hold, with the banner, never written: it may be a copy Duplicate
  made with the same `_key` while B removed the original (#29180 review,
  P1b-P1d), and the post cannot tell. Two rows of that key: dropped, as
  before.
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
  defp autosave(a, sections, owners) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params =
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

    render_hook(a, "autosave", params)
  end

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp held_words(a, path), do: words(get_in(form(a), path))

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} E13: B moves i1 from s1 to s2; A's old page types in i1: held at the moved row, nothing lost",
         c do
      put_doc(c, [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s1", []), sec("s2", [it("i2", "beta"), it("i1", "alpha")])])

      html =
        autosave(
          a,
          [{"s1", [{"i1", "<p>alpha A</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}],
          owners
        )

      # Before: A's words dropped, no banner.
      assert held(a) == ["doc[sections][1].items[1].rt"],
             "A's words were not held: #{inspect(held(a))}"

      assert held_words(a, ["sections", Access.at(1), "items", Access.at(1), "rt"]) == ["alpha A"]
      assert html =~ "doc-conflict-banner"
      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha"]}]}]
    end

    test "#{surface} E13, B also edits i1: B kept, A held", c do
      put_doc(c, [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s1", []), sec("s2", [it("i2", "beta"), it("i1", "alpha B")])])

      html =
        autosave(
          a,
          [{"s1", [{"i1", "<p>alpha A</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}],
          owners
        )

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha B"]}]}],
             "A's post was written over B's edit: #{inspect(shape(stored(c)))}"

      assert held(a) == ["doc[sections][1].items[1].rt"]
      assert held_words(a, ["sections", Access.at(1), "items", Access.at(1), "rt"]) == ["alpha A"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} E13, A did not type in i1: nothing held, nothing written", c do
      put_doc(c, [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s1", []), sec("s2", [it("i2", "beta"), it("i1", "alpha")])])

      html =
        autosave(
          a,
          [{"s1", [{"i1", "<p>alpha</p>"}]}, {"s2", [{"i2", "<p>beta A</p>"}]}],
          owners
        )

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta A"]}, {"i1", ["alpha"]}]}]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    # #29180 review: Duplicate re-keys the section, not its items, so the
    # copy's i1 has the original's `_key`. With the original gone, the one
    # i1 left is the copy: A's words are held there, never written into it.
    test "#{surface} P1b: B duplicates s1 and removes the original i1; A types in it: the copy kept, A held",
         c do
      put_doc(c, [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])])
      a = tab(c, @surface)
      owners = page_owners(a)

      b_saves(c, a, [
        sec("s1", []),
        sec("s1x", [it("i1", "alpha")]),
        sec("s2", [it("i2", "beta")])
      ])

      html =
        autosave(
          a,
          [{"s1", [{"i1", "<p>alpha A</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}],
          owners
        )

      assert shape(stored(c)) == [
               {"s1", []},
               {"s1x", [{"i1", ["alpha"]}]},
               {"s2", [{"i2", ["beta"]}]}
             ],
             "A's words were written into the copy: #{inspect(shape(stored(c)))}"

      assert held(a) == ["doc[sections][1].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} P1c: A drew the copy before the original; B removes the original i1: the copy kept, A held",
         c do
      put_doc(c, [
        sec("s1x", [it("i1", "alpha")]),
        sec("s1", [it("i1", "alpha")]),
        sec("s2", [it("i2", "beta")])
      ])

      a = tab(c, @surface)
      owners = page_owners(a)

      b_saves(c, a, [
        sec("s1x", [it("i1", "alpha")]),
        sec("s1", []),
        sec("s2", [it("i2", "beta")])
      ])

      html =
        autosave(
          a,
          [
            {"s1x", [{"i1", "<p>alpha</p>"}]},
            {"s1", [{"i1", "<p>alpha A</p>"}]},
            {"s2", [{"i2", "<p>beta</p>"}]}
          ],
          owners
        )

      assert shape(stored(c)) == [
               {"s1x", [{"i1", ["alpha"]}]},
               {"s1", []},
               {"s2", [{"i2", ["beta"]}]}
             ],
             "A's words were written into the copy: #{inspect(shape(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} P1d: A's page posts only the section it typed in; B removed the original i1: the copy kept, A held",
         c do
      put_doc(c, [
        sec("s1", [it("i1", "alpha"), it("i3", "gamma")]),
        sec("s1x", [it("i1", "alpha")])
      ])

      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s1", [it("i3", "gamma")]), sec("s1x", [it("i1", "alpha")])])

      html = autosave(a, [{"s1", [{"i1", "<p>alpha A</p>"}, {"i3", "<p>gamma</p>"}]}], owners)

      assert shape(stored(c)) == [{"s1", [{"i3", ["gamma"]}]}, {"s1x", [{"i1", ["alpha"]}]}],
             "A's words were written into the copy: #{inspect(shape(stored(c)))}"

      assert held(a) == ["doc[sections][1].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} two rows of i1 now: nothing written into either, as before", c do
      put_doc(c, [
        sec("s1", [it("i1", "alpha")]),
        sec("s2", [it("i2", "beta")]),
        sec("s3", [it("i1", "gamma")])
      ])

      a = tab(c, @surface)
      owners = page_owners(a)

      b_saves(c, a, [
        sec("s1", []),
        sec("s2", [it("i2", "beta"), it("i1", "alpha")]),
        sec("s3", [it("i1", "gamma")])
      ])

      autosave(
        a,
        [
          {"s1", [{"i1", "<p>alpha A</p>"}]},
          {"s2", [{"i2", "<p>beta</p>"}]},
          {"s3", [{"i1", "<p>gamma</p>"}]}
        ],
        owners
      )

      assert shape(stored(c)) == [
               {"s1", []},
               {"s2", [{"i2", ["beta"]}, {"i1", ["alpha"]}]},
               {"s3", [{"i1", ["gamma"]}]}
             ]
    end
  end
end
