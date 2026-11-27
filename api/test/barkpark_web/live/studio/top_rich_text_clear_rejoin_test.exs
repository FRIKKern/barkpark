defmodule BarkparkWeb.Studio.TopRichTextClearRejoinTest do
  @moduledoc """
  task-2e5deec3fa974d15 (#29148 review, F3b). A clears a Portable Text body
  and types new words, on the same page or after a rejoin. The editor posts
  its text's HTML, and a cleared contenteditable is `<br>`, `<p></p>` or
  `<p><br></p>` as often as `""`. Every shape but `""` was stored as `[]`,
  and a stored `[]` body read as an empty PortableDoc block list
  (`Forms.historical_body_blocks/1`): the save kept it and dropped A's
  words, with no banner. `""` stores no body, so it never took that path.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, schema} = Content.get_schema(c.type, "production")

    fields =
      Enum.map(schema.fields, fn
        %{"name" => "body"} = f -> Map.put(f, "format", "portableText")
        f -> f
      end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => fields
        },
        "production"
      )

    c
  end

  defp body(c), do: stored(c)["body"]

  # B's write through the store, as `/v1` makes it: the string as given.
  defp put_body(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    content =
      if value == :drop,
        do: Map.delete(doc.content, "body"),
        else: Map.put(doc.content, "body", value)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
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

  # LiveViewTest always joins with `_mounts: 0`: the rejoin is the state
  # `TextConfirmed.loaded/1` gives a socket that mounted as one.
  defp rejoined(c, surface) do
    view = tab(c, surface)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :editor_rt_rejoin, MapSet.new(["doc[body]"])))
    end)

    view
  end

  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp types(view, html, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[body]"],
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  for surface <- [:desk, :studio], clear <- ["", "<br>", "<p></p>", "<p><br></p>"] do
    @surface surface
    @clear clear

    test "#{surface} clear #{inspect(clear)}: rejoin, A types new words: written", c do
      put_body(c, "<p>body0</p>")
      a = tab(c, @surface)
      types(a, @clear, page(a))
      assert body(c) in [nil, []], "the clear was not stored: no test"
      seen = page(a)
      GenServer.stop(a.pid, :normal)
      a2 = rejoined(c, @surface)
      html = types(a2, "<p>new A</p>", seen)
      # Before: [] stored, no banner.
      assert words(body(c) || []) == ["new A"], "A's words were not written: #{inspect(body(c))}"
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} clear #{inspect(clear)}, no rejoin: A types new words: written", c do
      put_body(c, "<p>body0</p>")
      a = tab(c, @surface)
      types(a, @clear, page(a))
      html = types(a, "<p>new A</p>", page(a))
      assert words(body(c) || []) == ["new A"], "A's words were not written: #{inspect(body(c))}"
      refute html =~ "doc-conflict-banner"
    end
  end
end
