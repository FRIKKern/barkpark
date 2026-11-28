defmodule BarkparkWeb.Studio.NestedRowDupKeyTest do
  @moduledoc """
  task-a35e29de94927377 (#29165 review, W1). Two rows of one array share a
  `_key` (written past the API's own checks). B inserts a row; A's post,
  typed on the draw before it, names A's row by that key, which names no
  one row, and the fold wrote A's leaves by the old index: into B's new
  row, with no banner. Such a key now goes by index only while the rows
  are the ones the post names; else A's leaves are dropped and A's words
  shown in the banner (`DroppedRows`).
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
          {"doc[sections][0].items[#{i}]._key", elem(html, 0)},
          {"doc[sections][0].items[#{i}].rt", elem(html, 1)}
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

  defp kt(k, text), do: %{"_type" => "item", "_key" => k, "rt" => [block("k" <> text, text)]}

  defp lost(a),
    do:
      for(
        {{:lost, n}, t} <- :sys.get_state(a.pid).socket.assigns[:editor_rt_clash] || %{},
        do: {n, t}
      )

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} W1: B inserts a row before two rows of one key; A types in the first: B's row kept, A's words shown",
         c do
      put_items(c, [kt("d", "alpha"), kt("d", "beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [kt("n", "zed B"), kt("d", "alpha"), kt("d", "beta")])

      html = autosave(a, [{"d", "<p>alpha A</p>"}, {"d", "<p>beta</p>"}], owners)

      # Before: [["alpha A"], ["beta"], ["beta"]], B's "zed B" gone, no banner.
      assert items_words(stored(c)) == [["zed B"], ["alpha"], ["beta"]],
             "A's post was written over B's new row: #{inspect(items_words(stored(c)))}"

      assert lost(a) == [{"doc[sections][0].items[0].rt", ["alpha A"]}]
      assert html =~ "doc-conflict-lost"
    end

    test "#{surface} W1: B inserts a row between them; A types in the second: B's row kept, A's words shown",
         c do
      put_items(c, [kt("d", "alpha"), kt("d", "beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [kt("d", "alpha"), kt("n", "zed B"), kt("d", "beta")])

      html = autosave(a, [{"d", "<p>alpha</p>"}, {"d", "<p>beta A</p>"}], owners)

      # Before: [["alpha"], ["beta A"], ["beta"]].
      assert items_words(stored(c)) == [["alpha"], ["zed B"], ["beta"]],
             "A's post was written over B's new row: #{inspect(items_words(stored(c)))}"

      assert lost(a) == [{"doc[sections][0].items[1].rt", ["beta A"]}]
      assert html =~ "doc-conflict-lost"
    end

    test "#{surface} W1: B removes the first of them; A types in it: B's removal kept, A's words shown",
         c do
      put_items(c, [kt("d", "alpha"), kt("d", "beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [kt("d", "beta")])

      html = autosave(a, [{"d", "<p>alpha A</p>"}, {"d", "<p>beta</p>"}], owners)

      assert items_words(stored(c)) == [["beta"]],
             "A's post was written over the row left: #{inspect(items_words(stored(c)))}"

      assert lost(a) == [{"doc[sections][0].items[0].rt", ["alpha A"]}]
      assert html =~ "doc-conflict-lost"
    end

    test "#{surface} control: rows of one key, nothing moved: A's words written by index", c do
      put_items(c, [kt("d", "alpha"), kt("d", "beta")])
      a = tab(c, @surface)

      html = autosave(a, [{"d", "<p>alpha</p>"}, {"d", "<p>beta A</p>"}], page_owners(a))

      assert items_words(stored(c)) == [["alpha"], ["beta A"]]
      assert lost(a) == []
      refute html =~ "doc-conflict-banner"
    end
  end
end
