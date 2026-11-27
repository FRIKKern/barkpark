defmodule BarkparkWeb.Studio.NestedRowRichTextTest do
  @moduledoc """
  task-19452fe7c3af65d4. A rich text two or more rows deep (an array in a
  row, an object in a row) was written as posted: `ObjectRebase.keyed_rows`
  read only a row's own rich text, so A's post typed on the first draw was
  written over B's saves of that text and of the rows beside it, with no
  banner. It is now read as a row's own rich text is: merged with B's, or
  B's kept and A held.

  Also task-3811ae4146de3c91: `RowDraws` kept a row's draws by its inner
  `_key` alone, so two sections whose items share a key (a duplicated
  section) shared one list of at most 8, and B's saves of one section
  pushed the other's draws out. Draws are now kept by every row key on the
  way.
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
      # An array in a row.
      array("sections", member("section", [array("items", member("item", [rt()]))])),
      # An object in a row.
      array(
        "rows",
        member("row", [
          %{"name" => "box", "title" => "Box", "type" => "composite", "fields" => [rt()]}
        ])
      ),
      # Three deep.
      array(
        "deep",
        member("part", [array("items", member("item", [array("notes", member("note", [rt()]))]))])
      )
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

  defp put_doc(c, content) do
    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "T0", "content" => content},
        "production"
      )
  end

  # B's save, taken by A's socket.
  defp b_saves(c, a, content) do
    put_doc(c, content)

    assert eventually(fn -> Map.take(texts(form(a)), Map.keys(content)) == texts(content) end),
           "A's socket did not take B's save: no test"
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

    assert eventually(fn ->
             match?(
               {_, %{} = d} when map_size(d) > 0,
               :sys.get_state(view.pid).socket.assigns[:editor_rt_row_draws]
             )
           end),
           "no row draws recorded: no test"

    view
  end

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  # Every rich text's words, by path, in a content map (blocks) or a form.
  defp texts(content) when is_map(content) do
    for {k, v} <- content, k in ~w(sections rows deep), into: %{}, do: {k, words_in(v)}
  end

  defp words_in(list) when is_list(list) do
    if Enum.all?(list, &match?(%{"_type" => "block"}, &1)) and list != [],
      do: words(list),
      else: Enum.map(list, &words_in/1)
  end

  defp words_in(%{} = map),
    do: for({k, v} <- Enum.sort(map), k not in ~w(_key _type), do: {k, words_in(v)})

  defp words_in(v), do: v

  # The page's post of `content`, its rich texts as HTML, with the owner
  # entries the page drew.
  defp autosave(a, content, target, owners) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params =
      content
      |> Enum.flat_map(fn {k, v} -> flat("doc[#{k}]", v) end)
      |> Map.new()
      |> Map.put("doc[title]", "T0")
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => [target],
        "_bp_rt_owner" => owners
      })

    render_hook(a, "autosave", params)
  end

  defp flat(prefix, [%{"_type" => "block"} | _] = blocks),
    do: [{prefix, Enum.map_join(blocks, &"<p>#{hd(&1["children"])["text"]}</p>")}]

  defp flat(prefix, list) when is_list(list),
    do: list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> flat("#{prefix}[#{i}]", v) end)

  defp flat(prefix, %{} = map), do: Enum.flat_map(map, fn {k, v} -> flat("#{prefix}.#{k}", v) end)
  defp flat(prefix, v), do: [{prefix, v}]

  defp b(key, text), do: block(key, text)

  defp section(key, ikey, blocks),
    do: %{
      "_type" => "section",
      "_key" => key,
      "items" => [%{"_type" => "item", "_key" => ikey, "rt" => blocks}]
    }

  for surface <- [:desk, :studio] do
    @surface surface

    # Each draw of a row rich text is kept, up to 8 a row (`RowDraws`). B
    # edits s1's second block, then saves s2 six times; A's page still shows
    # the first draw of both, and A types in s1's first block.
    for ikeys <- [["i1", "i1"], ["i1", "i2"]] do
      @ikeys ikeys

      test "#{surface} array in a row, items #{Enum.join(ikeys, "/")}: B edits s1 and saves s2 six times; A types in s1 apart: merged",
           c do
        [k1, k2] = @ikeys
        s1 = fn second -> section("s1", k1, [b("a1", "alpha"), b("a2", second)]) end
        put_doc(c, %{"sections" => [s1.("gamma"), section("s2", k2, [b("b1", "beta")])]})
        a = tab(c, @surface)
        owners = page_owners(a)

        for n <- 0..6 do
          s2 = section("s2", k2, [b("b1", if(n == 0, do: "beta", else: "beta #{n}"))])
          b_saves(c, a, %{"sections" => [s1.("gamma B"), s2]})
        end

        a_post = %{
          "sections" => [
            section("s1", k1, [b("a1", "alpha A"), b("a2", "gamma")]),
            section("s2", k2, [b("b1", "beta")])
          ]
        }

        html = autosave(a, a_post, "doc[sections][0].items[0].rt", owners)

        # Before: A's post written as posted ("gamma", "beta"); with one list
        # of draws for both items, A held and its words lost.
        assert texts(stored(c))["sections"] == [
                 [{"items", [[{"rt", ["alpha A", "gamma B"]}]]}],
                 [{"items", [[{"rt", ["beta 6"]}]]}]
               ],
               "A's words were not merged with B's: #{inspect(texts(stored(c)))}"

        assert held(a) == [], "A was held, typing apart from B"
        refute html =~ @rb
      end
    end

    test "#{surface} array in a row: B and A edit the same block: B's kept, A held", c do
      put_doc(c, %{"sections" => [section("s1", "i1", [b("a1", "alpha")])]})
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, %{"sections" => [section("s1", "i1", [b("a1", "alpha B")])]})

      html =
        autosave(
          a,
          %{"sections" => [section("s1", "i1", [b("a1", "alpha A")])]},
          "doc[sections][0].items[0].rt",
          owners
        )

      assert texts(stored(c))["sections"] == [[{"items", [[{"rt", ["alpha B"]}]]}]],
             "A's post was written over B's: #{inspect(texts(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} object in a row: B edits the second block, A the first: merged", c do
      row = fn t1, t2 ->
        %{"_type" => "row", "_key" => "r1", "box" => %{"rt" => [b("a1", t1), b("a2", t2)]}}
      end

      put_doc(c, %{"rows" => [row.("alpha", "gamma")]})
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, %{"rows" => [row.("alpha", "gamma B")]})

      html = autosave(a, %{"rows" => [row.("alpha A", "gamma")]}, "doc[rows][0].box.rt", owners)

      assert texts(stored(c))["rows"] == [[{"box", [{"rt", ["alpha A", "gamma B"]}]}]],
             "A's post was written over B's: #{inspect(texts(stored(c)))}"

      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} three deep: B edits the second block, A the first: merged", c do
      part = fn t1, t2 ->
        note = %{"_type" => "note", "_key" => "n1", "rt" => [b("a1", t1), b("a2", t2)]}

        %{
          "_type" => "part",
          "_key" => "p1",
          "items" => [%{"_type" => "item", "_key" => "i1", "notes" => [note]}]
        }
      end

      put_doc(c, %{"deep" => [part.("alpha", "gamma")]})
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, %{"deep" => [part.("alpha", "gamma B")]})

      html =
        autosave(
          a,
          %{"deep" => [part.("alpha A", "gamma")]},
          "doc[deep][0].items[0].notes[0].rt",
          owners
        )

      assert texts(stored(c))["deep"] == [
               [{"items", [[{"notes", [[{"rt", ["alpha A", "gamma B"]}]]}]]}]
             ],
             "A's post was written over B's: #{inspect(texts(stored(c)))}"

      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} control: A alone types in a nested row: written, no banner", c do
      put_doc(c, %{"sections" => [section("s1", "i1", [b("a1", "alpha")])]})
      a = tab(c, @surface)

      html =
        autosave(
          a,
          %{"sections" => [section("s1", "i1", [b("a1", "alpha A")])]},
          "doc[sections][0].items[0].rt",
          page_owners(a)
        )

      assert texts(stored(c))["sections"] == [[{"items", [[{"rt", ["alpha A"]}]]}]]
      assert held(a) == []
      refute html =~ @rb
    end
  end
end
