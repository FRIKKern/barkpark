defmodule BarkparkWeb.Studio.RichTextImagePostQuotingTest do
  @moduledoc """
  task-6a5c3e075299d4bc (#29288 r1 review, L2). A post that is not
  byte-equal to the editor's drawn HTML, but reads as the same blocks, is
  untouched: the stored value is kept as it is. A browser posts `"` where the
  server drew `&quot;` after A types and undoes. Read against the stored
  blocks instead, two blocks of one `_key` were written back with the second
  renamed, a write with no change.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  alias Barkpark.Content.PortableText
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
        %{"name" => c.type, "title" => "O", "visibility" => "public", "fields" => fields},
        "production"
      )

    c
  end

  defp set_body(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "body", value)
        },
        "production"
      )
  end

  defp tab(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp page_seen(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp post(view, "autosave", html, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[body]"],
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp post(view, "save", html, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp blk(key, text) do
    %{
      "_type" => "block",
      "_key" => key,
      "style" => "normal",
      "markDefs" => [],
      "children" => [%{"_type" => "span", "_key" => key <> "s", "text" => text, "marks" => []}]
    }
  end

  defp keys(c), do: Enum.map(stored(c)["body"], & &1["_key"])

  for surface <- [:desk, :studio], how <- ["autosave", "save"] do
    @surface surface
    @how how

    test "#{surface} #{how} L2: two blocks of one _key, the browser's quoting of the drawn text: kept as stored",
         c do
      body = [blk("b1", ~s(say "hi")), blk("b1", ~s(say "hi"))]
      set_body(c, body)
      a = tab(c, @surface)
      refute PortableText.to_html(body) == ~s(<p>say "hi"</p><p>say "hi"</p>)

      post(a, @how, ~s(<p>say "hi"</p><p>say "hi"</p>), page_seen(a))

      # Before: ["b1", "b1n1"], the second block renamed with no change.
      assert keys(c) == ["b1", "b1"], "an unchanged post was rewritten: #{inspect(keys(c))}"
      assert stored(c)["body"] == body
    end

    test "#{surface} #{how} control: the drawn HTML posted back: kept as stored", c do
      body = [blk("b1", ~s(say "hi")), blk("b1", ~s(say "hi"))]
      set_body(c, body)
      a = tab(c, @surface)

      post(a, @how, PortableText.to_html(body), page_seen(a))

      assert stored(c)["body"] == body
    end

    test "#{surface} #{how} control: a typed word in one of the blocks is written", c do
      set_body(c, [blk("b1", ~s(say "hi")), blk("b2", "two")])
      a = tab(c, @surface)

      post(a, @how, ~s(<p>say "hi" now</p><p>two</p>), page_seen(a))

      assert words(stored(c)["body"]) == [~s(say "hi" now), "two"]
      assert keys(c) == ["b1", "b2"]
    end
  end
end
