defmodule BarkparkWeb.Studio.NestedRowMovedRepostTest do
  @moduledoc """
  task-3422ba9e403f8b75, #29180 review round 2. A's words held at a row
  another editor moved (or at a Duplicate copy of it) stay held on the
  posts that follow. The hold put A's view in the form at the moved path;
  the next post from A's stale page names the old path, so nothing read
  the held name, and the fold seeded the array from the form with A's
  view in it: written over the store (F1.1), over B's later save (F4), or
  into the copy (F8). A held path a post does not carry now gets the
  stored value. A post on the shown view, Reload, a Save and a title-only
  post behave as before (F2, F3, F5, F9), and so does a hold in place
  (F10).
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

  defp holds(a), do: :sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{}

  defp seen_autosave(a, sections, owners, seen) do
    params = a |> post_params(sections, owners) |> Map.put("_bp_rt_seen", seen)
    render_hook(a, "autosave", params)
  end

  defp save(a, sections, owners) do
    params = a |> post_params(sections, owners) |> Map.delete("_target")
    a |> element("#editor-form") |> render_submit(params)
  end

  defp title_only(a) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    render_hook(a, "autosave", %{
      "doc" => %{"title" => "T1"},
      "_target" => ["doc", "title"],
      "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id)
    })
  end

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp held_words(a, path), do: words(get_in(form(a), path))

  defp two, do: [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])]
  defp moved, do: [sec("s1", []), sec("s2", [it("i2", "beta"), it("i1", "alpha")])]
  defp copied, do: [sec("s1", []), sec("s1x", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])]
  defp stale, do: [{"s1", [{"i1", "<p>alpha A</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}]

  @moved_at "doc[sections][1].items[1].rt"
  defp moved_path, do: ["sections", Access.at(1), "items", Access.at(1), "rt"]

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} F1.1: held at the moved row; A's stale page posts again: still held, never written",
         c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, moved())
      autosave(a, stale(), owners)

      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha"]}]}],
             "A's held words were written: #{inspect(shape(stored(c)))}"

      assert held(a) == [@moved_at]
      assert held_words(a, moved_path()) == ["alpha A"]
      assert html =~ "doc-conflict-banner"

      autosave(
        a,
        [{"s1", [{"i1", "<p>alpha A more</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}],
        owners
      )

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha"]}]}]
    end

    test "#{surface} F4: held at the moved row; B saves it again; A's stale page posts: B's save kept",
         c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, moved())
      autosave(a, stale(), owners)

      b2 = [sec("s1", []), sec("s2", [it("i2", "beta"), it("i1", "alpha B2")])]
      put_doc(c, b2)

      assert eventually(fn ->
               assigns = :sys.get_state(a.pid).socket.assigns
               inspect(assigns, limit: :infinity, printable_limit: :infinity) =~ "alpha B2"
             end),
             "A's socket did not hear B's second save: no test"

      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha B2"]}]}],
             "B's second save was lost: #{inspect(shape(stored(c)))}"

      assert @moved_at in held(a)
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} F8: held at a Duplicate copy; A's stale page posts again: the copy kept",
         c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, copied())
      autosave(a, stale(), owners)

      html = autosave(a, stale(), owners)

      assert shape(stored(c)) == [
               {"s1", []},
               {"s1x", [{"i1", ["alpha"]}]},
               {"s2", [{"i2", ["beta"]}]}
             ],
             "A's words were written into the copy: #{inspect(shape(stored(c)))}"

      assert held(a) == ["doc[sections][1].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} F2: held at the moved row; A types on the view it was shown: written, hold ends",
         c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, moved())
      autosave(a, stale(), owners)
      %{seq: seq} = holds(a)[@moved_at]

      seen_autosave(
        a,
        [{"s1", []}, {"s2", [{"i2", "<p>beta</p>"}, {"i1", "<p>alpha A Z</p>"}]}],
        page_owners(a),
        [@moved_at <> "|#{seq}"]
      )

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha A Z"]}]}]
      assert held(a) == []
    end

    test "#{surface} F3: held at a Duplicate copy; Reload ends the hold; a stale post is held again",
         c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, copied())
      autosave(a, stale(), owners)

      a |> element("[phx-click=reload-remote-doc]") |> render_click()

      assert held(a) == []
      assert shape(form(a)) == shape(%{"sections" => copied()})
      refute render(a) =~ "doc-conflict-banner"

      autosave(a, stale(), owners)

      assert shape(stored(c)) == shape(%{"sections" => copied()})
      assert held(a) == ["doc[sections][1].items[0].rt"]
    end

    test "#{surface} F5: a Save from the stale page holds A at the moved row, never written", c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, moved())

      save(a, stale(), owners)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha"]}]}]
      assert held(a) == [@moved_at]
    end

    test "#{surface} F9: held at the moved row; a title-only post: the row kept, still held",
         c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, moved())
      autosave(a, stale(), owners)

      title_only(a)

      assert shape(stored(c)) == [{"s1", []}, {"s2", [{"i2", ["beta"]}, {"i1", ["alpha"]}]}]
      assert held(a) == [@moved_at]
    end

    test "#{surface} F10: a hold in place; a stale re-post and a title-only post: B kept, still held",
         c do
      put_doc(c, two())
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s1", [it("i1", "alpha B")]), sec("s2", [it("i2", "beta")])])
      autosave(a, stale(), owners)
      assert held(a) == ["doc[sections][0].items[0].rt"]

      autosave(a, stale(), owners)
      assert shape(stored(c)) == [{"s1", [{"i1", ["alpha B"]}]}, {"s2", [{"i2", ["beta"]}]}]
      assert held(a) == ["doc[sections][0].items[0].rt"]

      title_only(a)
      assert shape(stored(c)) == [{"s1", [{"i1", ["alpha B"]}]}, {"s2", [{"i2", ["beta"]}]}]
      assert held(a) == ["doc[sections][0].items[0].rt"]
    end
  end
end
