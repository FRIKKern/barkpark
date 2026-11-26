defmodule BarkparkWeb.Studio.ObjectRichTextRowOwnMoveTest do
  @moduledoc """
  task-82519fd79663e072, #29040 r1 review: a row rich text post is read
  against the draw its owner entry names by the row's `_key` and digest
  (`RichTextRemote.RowDraws`), never by the row's index.

  B1: A moves a row, or removes the row above, then types in it, with
  nobody else editing. The draws were kept by index, so the moved row
  found none and A was held with "Someone else rewrote".

  N2: A's own post on a row was kept by index too: a row that slid under
  that index with the same text, and a B edit that drew A's words, read
  A's post on it against A's other row.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live
  @rb "Someone else rewrote"

  setup %{conn: conn}, do: setup_doc(conn)

  defp put_rows(c, rows) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = put_in(doc.content, ["meta", "rows"], rows)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp r(key, wkey, text), do: %{"_type" => "row", "_key" => key, "rt" => [block(wkey, text)]}
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})
  defp by_key(c), do: Map.new(stored(c)["meta"]["rows"] || [], &{&1["_key"], words(&1["rt"])})
  defp form_rows(a), do: Enum.map(form(a)["meta"]["rows"] || [], &{&1["_key"], words(&1["rt"])})

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  # A's post as the page sends it: `rows` are `{key, html}` by index.
  defp post(a, how, rows, owners) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {{k, html}, i} ->
        [
          {"doc[meta].rows[#{i}]._type", "row"},
          {"doc[meta].rows[#{i}]._key", k},
          {"doc[meta].rows[#{i}].rt", html}
        ]
      end)
      |> Map.new()
      |> Map.merge(%{"doc[meta].label" => "l0", "doc[title]" => "T0"})
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => ["doc[meta].rows[0].rt"],
        "_bp_rt_owner" => owners
      })

    render_hook(a, if(how == :auto, do: "autosave", else: "save"), params)
  end

  defp b(c, a, rows) do
    put_rows(c, rows)
    want = Enum.map(rows, &{&1["_key"], words(&1["rt"])})
    assert eventually(fn -> form_rows(a) == want end)
  end

  defp op(a, action, extra) do
    path =
      ~r/phx-value-path="([^"]*rows[^"]*)"/
      |> Regex.scan(render(a))
      |> Enum.map(fn [_, p] -> p end)
      |> hd()

    EditorPost.press(
      a,
      "array_op",
      Map.merge(%{"action" => action, "path" => path, "field" => "rows"}, extra)
    )
  end

  defp two(c) do
    put_rows(c, [r("r1", "w1", "one two"), r("r2", "w2", "three four")])
    open(c)
  end

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    test "#{surface} #{how}: A moves r1 down, then types in it: written, no banner", c do
      a = c |> Map.put(:surface, unquote(surface)) |> two()
      op(a, "move_down", %{"index" => "0"})
      assert Enum.map(form_rows(a), &elem(&1, 0)) == ["r2", "r1"]

      html =
        post(
          a,
          unquote(how),
          [{"r2", "<p>three four</p>"}, {"r1", "<p>ONE two</p>"}],
          page_owners(a)
        )

      # Before: held, and the store kept "one two".
      assert by_key(c)["r1"] == ["ONE two"]
      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} #{how}: A removes the row above, then types in the row below: written, no banner",
         c do
      a = c |> Map.put(:surface, unquote(surface)) |> two()
      op(a, "remove_row", %{"index" => "0"})
      assert Enum.map(form_rows(a), &elem(&1, 0)) == ["r2"]

      html = post(a, unquote(how), [{"r2", "<p>three FOUR</p>"}], page_owners(a))
      assert by_key(c) == %{"r2" => ["three FOUR"]}
      assert held(a) == []
      refute html =~ @rb
    end

    # #29040 r2 review, B1': a duplicate gets a fresh `_key`; no draw was
    # recorded under it, so A typing in the copy was held.
    test "#{surface} #{how}: A duplicates r1, then types in the copy: written, no banner", c do
      a = c |> Map.put(:surface, unquote(surface)) |> two()
      op(a, "duplicate_row", %{"index" => "0"})
      [{"r1", _}, {copy, _}, {"r2", _}] = form_rows(a)

      html =
        post(
          a,
          unquote(how),
          [{"r1", "<p>one two</p>"}, {copy, "<p>one two copy</p>"}, {"r2", "<p>three four</p>"}],
          page_owners(a)
        )

      assert by_key(c)[copy] == ["one two copy"]
      assert held(a) == []
      refute html =~ @rb
    end

    # #29040 r2 review, N-a: A's merged save puts "ONE twoB" in the form; A's
    # move remounts the row drawing it, a value no draw recorded.
    test "#{surface} #{how}: B edits, A's post merges, A moves the row and types: written, no banner",
         c do
      a = c |> Map.put(:surface, unquote(surface)) |> two()
      own = page_owners(a)
      b(c, a, [r("r1", "w1", "one twoB"), r("r2", "w2", "three four")])
      post(a, :auto, [{"r1", "<p>ONE two</p>"}, {"r2", "<p>three four</p>"}], own)
      assert by_key(c)["r1"] == ["ONE twoB"]

      op(a, "move_down", %{"index" => "0"})

      html =
        post(
          a,
          unquote(how),
          [{"r2", "<p>three four</p>"}, {"r1", "<p>ONE twoB!</p>"}],
          page_owners(a)
        )

      assert by_key(c)["r1"] == ["ONE twoB!"]
      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} #{how}: A's own post on r1 is not r2's draw after r2 slides to its index",
         c do
      c = Map.put(c, :surface, unquote(surface))
      put_rows(c, [r("r1", "w1", "one two"), r("r2", "w2", "one two")])
      a = open(c)
      post(a, unquote(how), [{"r1", "<p>one twoA</p>"}, {"r2", "<p>one two</p>"}], page_owners(a))

      # B removes r1: r2, the same text, slides to index 0. Then B edits r2
      # to the words A gave r1.
      b(c, a, [r("r2", "w2", "one two")])
      drawn = page_owners(a)
      b(c, a, [r("r2", "w2", "one twoA")])

      # Before: read against A's r1 post ("one twoA"), so B's edit read as
      # A's and "ONE two" was written over it.
      post(a, unquote(how), [{"r2", "<p>ONE two</p>"}], drawn)

      assert by_key(c)["r2"] == ["ONE twoA"] or
               (held(a) != [] and by_key(c)["r2"] == ["one twoA"])
    end
  end
end
