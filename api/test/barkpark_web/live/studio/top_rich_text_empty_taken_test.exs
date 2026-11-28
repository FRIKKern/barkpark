defmodule BarkparkWeb.Studio.TopRichTextEmptyTakenTest do
  @moduledoc """
  task-458319d6bec784c8 (#29177 review, P6). A Portable Text field is empty.
  B fills it and saves; A's socket takes B's save, but A's page has not
  drawn it yet: A's first-words post carries the old seen (the empty draw).
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
    f = %{"name" => "body2", "title" => "body2", "type" => "richText", "format" => "portableText"}

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => schema.fields ++ [f]
        },
        "production"
      )

    c
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

  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  # B's write through the store.
  defp set2(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "body2", value)
        },
        "production"
      )
  end

  defp types(view, html, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[body2]"],
      "doc" => %{"title" => "T0", "body2" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp body2(c), do: stored(c)["body2"]
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} P6: B fills the empty field, A's socket takes it, A posts first words on the old draw: B kept, A held",
         c do
      a = tab(c, @surface)
      seen = page(a)
      set2(c, [block("k9", "B2")])
      assert eventually(fn -> form(a)["body2"] not in [nil, "", []] end)

      html = types(a, "<p>A2</p>", seen)

      # Before: ["A2"] written over B's ["B2"], no banner.
      assert words(body2(c) || []) == ["B2"],
             "A's post was written over B's: #{inspect(body2(c))}"

      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} P6b: the field holds X, B saves X B, A posts X A on the old draw: B kept, A held",
         c do
      set2(c, [block("k1", "X")])
      a = tab(c, @surface)
      seen = page(a)
      set2(c, [block("k1", "X B")])
      assert eventually(fn -> inspect(form(a)["body2"]) =~ "X B" end)

      html = types(a, "<p>X A</p>", seen)

      assert words(body2(c) || []) == ["X B"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A's page drew B's words, A adds to them: written, no hold", c do
      a = tab(c, @surface)
      set2(c, [block("k9", "B2")])
      assert eventually(fn -> form(a)["body2"] not in [nil, "", []] end)
      render(a)

      html = types(a, "<p>B2</p><p>A2</p>", page(a))

      assert words(body2(c) || []) == ["B2", "A2"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A alone types first words in the empty field: written", c do
      a = tab(c, @surface)
      html = types(a, "<p>A2</p>", page(a))
      assert words(body2(c) || []) == ["A2"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end
  end
end
