defmodule BarkparkWeb.Studio.NestedRowRemovedTest do
  @moduledoc """
  task-c5534fec656190fc (#29164 review, E8). B removes section s1 while A's
  page, not yet redrawn, types in its item. The fold (`Fields.row_path/4`)
  has no row to write A's words into and dropped them with no word. They
  are now shown in the conflict banner, with a line that says why, so A can
  copy them. A dropped row A did not type in says nothing.
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

  defp mine(view) do
    ~r/<blockquote[^>]*data-version="mine"[^>]*>(.*?)<\/blockquote>/s
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, t] -> String.trim(t) end)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} E8: B removes the section A types in: A's words in the banner", c do
      put_doc(c, [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s2", [it("i2", "beta")])])

      html =
        autosave(
          a,
          [{"s1", [{"i1", "<p>alpha A</p>"}]}, {"s2", [{"i2", "<p>beta</p>"}]}],
          owners
        )

      assert shape(stored(c)) == [{"s2", [{"i2", ["beta"]}]}]

      # Before: no banner, A's words gone.
      assert html =~ "doc-conflict-banner", "A's words were dropped with no banner"
      assert html =~ @lost
      assert mine(a) == ["alpha A"]
      # Reload takes the store's, and ends A's kept words with the banner.
      a |> element(~s([data-test-id="doc-conflict-reload"])) |> render_click()
      assert eventually(fn -> mine(a) == [] and not (render(a) =~ "doc-conflict-banner") end)
    end

    test "#{surface} B removes a section A did not type in; A types in another: no banner", c do
      put_doc(c, [sec("s1", [it("i1", "alpha")]), sec("s2", [it("i2", "beta")])])
      a = tab(c, @surface)
      owners = page_owners(a)
      b_saves(c, a, [sec("s2", [it("i2", "beta")])])

      html =
        autosave(
          a,
          [{"s1", [{"i1", "<p>alpha</p>"}]}, {"s2", [{"i2", "<p>beta A</p>"}]}],
          owners
        )

      assert shape(stored(c)) == [{"s2", [{"i2", ["beta A"]}]}]
      refute html =~ "doc-conflict-banner"
      assert mine(a) == []
    end
  end
end
