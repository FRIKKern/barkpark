defmodule BarkparkWeb.Studio.NestedRowEditorRemountTest do
  @moduledoc """
  task-d7a6ed432944fff5 (#29164 review, R1/R2). A row rich text editor sits
  in an ignored wrapper (`phx-update="ignore"`) whose id names its index and
  its own row's `_key`, so a remount reaches the page only when either
  changes. Two sections whose items share a `_key` (a duplicated section)
  then swap (A's own move, or B's save): every editor keeps its id, the page
  keeps the old texts at the old slots, and A's next post read each slot's
  text as the other section's. The id now names every row key on the way.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.EditorPost
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

  defp put_doc(c, sections) do
    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => "T0", "content" => %{"sections" => sections}},
        "production"
      )
  end

  defp sec(key, text),
    do: %{
      "_type" => "section",
      "_key" => key,
      "items" => [%{"_type" => "item", "_key" => "i1", "rt" => [block(key <> "b", text)]}]
    }

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

  defp form_keys(a), do: Enum.map(form(a)["sections"] || [], & &1["_key"])

  # What the page draws in each slot: the wrapper id, the editor's text and
  # its owner entry, as the browser keeps them (an ignored wrapper whose id
  # did not change keeps its old children).
  defp slots(view) do
    html = render(view)

    for i <- 0..1 do
      name = "doc[sections][#{i}].items[0].rt"

      [_, wrap, inner] =
        Regex.run(
          ~r/<div id="(bp-rt-sub-[^"]*)" phx-update="ignore"[^>]*data-pt-subfield="#{Regex.escape(name)}"[^>]*>(.*?)<\/bp-rich-text-editor>/s,
          html
        )

      [_, owner] = Regex.run(~r/name="_bp_rt_owner\[\]" value="([^"]*)"/, inner)
      [_, value] = Regex.run(~r/<bp-rich-text-editor value="([^"]*)"/, inner)
      %{wrap: wrap, owner: String.replace(owner, "&quot;", "\""), html: unescape(value)}
    end
  end

  defp unescape(v),
    do:
      v
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&amp;", "&")

  # A's post as the page sends it, slot by slot, with A's words added to
  # slot 1's text as the page shows it.
  defp types_in_slot_1(a, slots) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns
    keys = form_keys(a)

    params =
      slots
      |> Enum.with_index()
      |> Enum.flat_map(fn {slot, i} ->
        html = if i == 1, do: String.replace(slot.html, "</p>", " A</p>"), else: slot.html

        [
          {"doc[sections][#{i}]._type", "section"},
          {"doc[sections][#{i}]._key", Enum.at(keys, i)},
          {"doc[sections][#{i}].items[0]._type", "item"},
          {"doc[sections][#{i}].items[0]._key", "i1"},
          {"doc[sections][#{i}].items[0].rt", html}
        ]
      end)
      |> Map.new()
      |> Map.put("doc[title]", "T0")
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => ["doc[sections][1].items[0].rt"],
        "_bp_rt_owner" => Enum.map(slots, & &1.owner)
      })

    render_hook(a, "autosave", params)
  end

  defp stored_by_key(c),
    do: Map.new(stored(c)["sections"] || [], &{&1["_key"], words(hd(&1["items"])["rt"])})

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  for surface <- [:desk, :studio], who <- [:a_moves, :b_swaps] do
    @surface surface
    @who who

    test "#{surface} #{who}: sections sharing item key i1 swap; the editors remount, A's next post lands in its section",
         c do
      put_doc(c, [sec("s1", "alpha"), sec("s2", "beta")])
      a = tab(c, @surface)
      before = slots(a)

      case @who do
        :a_moves ->
          EditorPost.press(a, "array_op", %{
            "action" => "move_down",
            "field" => "sections",
            "path" => "doc[sections]",
            "index" => "0"
          })

        :b_swaps ->
          put_doc(c, [sec("s2", "beta"), sec("s1", "alpha")])
      end

      assert eventually(fn -> form_keys(a) == ["s2", "s1"] end), "the swap was not taken: no test"
      now = slots(a)

      # Before: both wrapper ids unchanged, so the page kept alpha in slot 0
      # and beta in slot 1.
      assert Enum.map(now, & &1.wrap) != Enum.map(before, & &1.wrap),
             "the editors were not remounted after the swap"

      assert Enum.map(now, & &1.html) == ["<p>beta</p>", "<p>alpha</p>"]

      html = types_in_slot_1(a, now)

      assert stored_by_key(c) == %{"s1" => ["alpha A"], "s2" => ["beta"]},
             "A's words did not land in its section: #{inspect(stored_by_key(c))}"

      assert held(a) == []
      refute html =~ @rb
    end
  end
end
