defmodule BarkparkWeb.Studio.NestedRowDuplicateKeyTest do
  @moduledoc """
  task-a35e29de94927377 (#29165 review, W1). Two rows of one array share a
  `_key` (written past the API's checks). B inserts a row before them; A's
  post, typed on the first draw, names its rows by their old indexes, and
  the fold, finding two rows of that key, fell back to the index: A's row
  was written over B's new one, `_key` and all. Rows of one key now go by
  their order among the post's rows of that key, when the post and the
  form hold as many; otherwise no row is matched, and A's words typed in
  one are shown in the banner (`RichTextRemote.DroppedRows`).
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

  defp it(key, text), do: %{"_type" => "item", "_key" => key, "rt" => [block("k" <> text, text)]}

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

  # A's post as its page sends it: `[{_key, html}]` by the index the page
  # drew them at.
  defp autosave(a, htmls, owners) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    params =
      htmls
      |> Enum.with_index()
      |> Enum.flat_map(fn {{key, html}, i} ->
        [
          {"doc[sections][0].items[#{i}]._type", "item"},
          {"doc[sections][0].items[#{i}]._key", key},
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

  defp keys(content), do: Enum.map(hd(content["sections"] || [%{}])["items"] || [], & &1["_key"])

  defp mine(view) do
    ~r/<blockquote[^>]*data-version="mine"[^>]*>(.*?)<\/blockquote>/s
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, t] -> String.trim(t) end)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} W1: B inserts a row before two rows of one key; A types in the first: B kept",
         c do
      put_items(c, [it("d", "alpha"), it("d", "beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("z", "zed B"), it("d", "alpha"), it("d", "beta")])

      html = autosave(a, [{"d", "<p>alpha A</p>"}, {"d", "<p>beta</p>"}], owners)

      # Before: keyed d, d, d with B's "zed B" lost.
      assert keys(stored(c)) == ["z", "d", "d"],
             "A's row was written over B's new one: #{inspect(keys(stored(c)))}"

      assert items_words(stored(c)) == [["zed B"], ["alpha A"], ["beta"]],
             "not merged: #{inspect(items_words(stored(c)))}"

      assert held(a) == []
      refute html =~ @rb
    end

    test "#{surface} B takes one of two rows of a key out and inserts one: nothing written over B, A's words in the banner",
         c do
      put_items(c, [it("d", "alpha"), it("d", "beta")])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [it("z", "zed B"), it("d", "alpha")])

      html = autosave(a, [{"d", "<p>alpha A</p>"}, {"d", "<p>beta</p>"}], owners)

      assert keys(stored(c)) == ["z", "d"]
      assert items_words(stored(c)) == [["zed B"], ["alpha"]]
      assert html =~ "doc-conflict-banner"
      assert mine(a) == ["alpha A"]
    end

    test "#{surface} control: A alone types in the second of two rows of one key: written", c do
      put_items(c, [it("d", "alpha"), it("d", "beta")])
      a = tab(c, @surface)

      html = autosave(a, [{"d", "<p>alpha</p>"}, {"d", "<p>beta A</p>"}], page_owners(a))

      assert items_words(stored(c)) == [["alpha"], ["beta A"]]
      assert held(a) == []
      refute html =~ @rb
    end
  end
end
