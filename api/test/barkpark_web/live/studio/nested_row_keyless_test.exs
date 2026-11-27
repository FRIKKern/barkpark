defmodule BarkparkWeb.Studio.NestedRowKeylessTest do
  @moduledoc """
  task-f10341a15bcac784 (#29164 review, E7b). Rows with no `_key` go by
  their index. B inserts a keyless item before A's; A's post, typed on the
  first draw, names A's item by its old index, and the fold writes it into
  the item now there, B's. `UnderLock` read that row's draw by index, but
  `ObjectRebase` rebased only rows with a `_key`, so A's text was written
  over B's new item with no banner. A keyless row is now read against the
  keyless row at its index: merged, or the store's kept and A held.
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
  defp autosave(a, htmls, owners) do
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

    render_hook(a, "autosave", params)
  end

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} E7b: B inserts a keyless item before A's; A's old page types in it: B kept, A held",
         c do
      put_items(c, [it("alpha")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("zed B"), it("alpha")])

      html = autosave(a, ["<p>alpha A</p>"], owners)

      # Before: [["alpha A"], ["alpha"]], B's "zed B" lost, no banner.
      assert items_words(stored(c)) == [["zed B"], ["alpha"]],
             "A's post was written over B's new item: #{inspect(items_words(stored(c)))}"

      assert held(a) == ["doc[sections][0].items[0].rt"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} E7: B edits one keyless item, A's old page types in the other: merged", c do
      put_items(c, [it("alpha"), it("beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("alpha"), it("beta B")])

      html = autosave(a, ["<p>alpha A</p>", "<p>beta</p>"], owners)

      assert items_words(stored(c)) == [["alpha A"], ["beta B"]],
             "not merged: #{inspect(items_words(stored(c)))}"

      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} control: A alone types in a keyless item: written", c do
      put_items(c, [it("alpha"), it("beta")])
      a = tab(c, @surface)

      html = autosave(a, ["<p>alpha A</p>", "<p>beta</p>"], page_owners(a))

      assert items_words(stored(c)) == [["alpha A"], ["beta"]]
      assert held(a) == []
      refute html =~ @rb
    end
  end
end
