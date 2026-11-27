defmodule BarkparkWeb.Studio.NestedRowDupInnerKeyTest do
  @moduledoc """
  task-1a748ef7bc04ae49, N1 from the #29165 re-check. Two sections each
  hold an item keyed i1, with different text. B puts an item before s2's
  i1 and adds a block to it; A's page, drawn before, types in s2's i1. An
  owner entry named only the item's own key, so it had two candidates,
  the row owner was not found, and A's post was written as drawn: B's
  block was lost with no banner. The entry names the section's key too,
  which picks s2's i1.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, schema} = Content.get_schema(c.type, "production")
    rt = %{"name" => "rt", "title" => "rt", "type" => "richText"}
    item = %{"type" => "composite", "name" => "item", "title" => "Item", "fields" => [rt]}

    row = %{
      "type" => "composite",
      "name" => "row",
      "title" => "Row",
      "fields" => [
        rt,
        %{"name" => "items", "title" => "Items", "type" => "arrayOf", "of" => [item]}
      ]
    }

    fields =
      Enum.map(schema.fields, fn
        %{"name" => "meta", "fields" => mf} = m ->
          %{
            m
            | "fields" =>
                Enum.map(mf, &if(&1["name"] == "rows", do: %{&1 | "of" => [row]}, else: &1))
          }

        f ->
          f
      end)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => c.type, "title" => "Nested", "visibility" => "public", "fields" => fields},
        "production"
      )

    c
  end

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

  defp it(key, text), do: %{"_type" => "item", "_key" => key, "rt" => [block("b" <> key, text)]}

  defp sec(key, items),
    do: %{
      "_type" => "row",
      "_key" => key,
      "rt" => [block("s" <> key, "sec " <> key)],
      "items" => items
    }

  defp items(rows),
    do:
      Enum.map(rows || [], fn r ->
        {r["_key"], Enum.map(r["items"] || [], &{&1["_key"], words(&1["rt"])})}
      end)

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  defp tab(c, surface), do: c |> Map.put(:surface, surface) |> open()

  defp post(a, how, secs, owners) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    flat =
      for {{k, shtml, its}, i} <- Enum.with_index(secs),
          pair <-
            [
              {"doc[meta].rows[#{i}]._type", "row"},
              {"doc[meta].rows[#{i}]._key", k},
              {"doc[meta].rows[#{i}].rt", shtml}
            ] ++
              Enum.flat_map(Enum.with_index(its), fn {{ik, h}, j} ->
                [
                  {"doc[meta].rows[#{i}].items[#{j}]._type", "item"},
                  {"doc[meta].rows[#{i}].items[#{j}]._key", ik},
                  {"doc[meta].rows[#{i}].items[#{j}].rt", h}
                ]
              end),
          into: %{"doc[meta].label" => "l0", "doc[title]" => "T0"},
          do: pair

    params =
      flat
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => ["doc[meta].rows[1].items[0].rt"],
        "_bp_rt_owner" => owners
      })

    render_hook(a, if(how == :autosave, do: "autosave", else: "save"), params)
  end

  for surface <- [:studio, :desk], how <- [:autosave, :save] do
    @surface surface
    @how how

    test "#{surface} #{how}: B puts an item before s2's i1 (s1 has an i1 too) and edits it; A's stale post merges into it",
         c do
      put_rows(c, [sec("s1", [it("i1", "a")]), sec("s2", [it("i1", "c")])])
      a = tab(c, @surface)
      owners = page_owners(a)

      b_i1 = %{it("i1", "c") | "rt" => [block("bi1", "c"), block("bi1b", "c B")]}
      b = [sec("s1", [it("i1", "a")]), sec("s2", [it("i0", "new"), b_i1])]
      put_rows(c, b)
      assert eventually(fn -> items(form(a)["meta"]["rows"]) == items(b) end)

      html =
        post(
          a,
          @how,
          [
            {"s1", "<p>sec s1</p>", [{"i1", "<p>a</p>"}]},
            {"s2", "<p>sec s2</p>", [{"i1", "<p>c A</p>"}]}
          ],
          owners
        )

      s2 = Map.new(items(stored(c)["meta"]["rows"]))["s2"]

      assert s2 == [{"i0", ["new"]}, {"i1", ["c A", "c B"]}],
             "B's block in s2's i1 was lost, or A's not merged: #{inspect(s2)}"

      assert Map.new(items(stored(c)["meta"]["rows"]))["s1"] == [{"i1", ["a"]}]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end
  end
end
