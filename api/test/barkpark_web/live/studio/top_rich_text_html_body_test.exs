defmodule BarkparkWeb.Studio.TopRichTextHtmlBodyTest do
  @moduledoc """
  task-bb19ab06ab1e87b2: which top-level rich text the store holds as an
  HTML string, and whether a later Studio save ever turns it into blocks.

  `RichTextFormat` reads a richText named `body` or `blocks` with no
  `format` and no block editor as `:legacy`: its stored value decides. Such
  a field with no value is written as the posted HTML string, and a string
  stays a string on every later save. Any other top-level richText is
  Portable Text: its first post is stored as blocks, and an HTML string
  stored before is turned into blocks on the next save.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, schema} = Content.get_schema(c.type, "production")
    fields = schema.fields ++ [%{"name" => "summary", "title" => "summary", "type" => "richText"}]

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

  defp set_field(c, key, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    content =
      if value == :drop, do: Map.delete(doc.content, key), else: Map.put(doc.content, key, value)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp open_tab(c, surface) do
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

  defp page_seen(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    String.replace(value, "&quot;", ~s("))
  end

  defp edit(view, key, fields),
    do:
      view
      |> element("#editor-form")
      |> render_change(%{
        "_target" => ["doc[#{key}]"],
        "doc" => Map.merge(%{"title" => "T0"}, fields),
        "_bp_seen" => page_seen(view)
      })

  defp save(view, fields),
    do:
      view
      |> element("#editor-form")
      |> render_submit(%{
        "doc" => Map.merge(%{"title" => "T0"}, fields),
        "_bp_seen" => page_seen(view)
      })

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: a legacy body with no value is stored as HTML, and stays HTML on every later save",
         c do
      set_field(c, "body", :drop)
      a = open_tab(c, @surface)
      edit(a, "body", %{"body" => "<p>B5</p>"})
      assert stored(c)["body"] == "<p>B5</p>"

      edit(a, "body", %{"body" => "<p>B5 A7</p>"})
      assert stored(c)["body"] == "<p>B5 A7</p>"

      save(a, %{"body" => "<p>B5 A7 A8</p>"})
      assert stored(c)["body"] == "<p>B5 A7 A8</p>"

      # A fresh tab reads it back as HTML and writes HTML again.
      b = open_tab(c, @surface)
      edit(b, "body", %{"body" => "<p>B5 A7 A8 B9</p>"})
      assert stored(c)["body"] == "<p>B5 A7 A8 B9</p>"
    end

    test "#{surface}: any other top-level rich text is stored as blocks, and an HTML string turns into blocks on the next save",
         c do
      a = open_tab(c, @surface)
      edit(a, "summary", %{"summary" => "<p>s1</p>"})
      assert words(stored(c)["summary"]) == ["s1"]

      set_field(c, "summary", "<p>old</p>")
      b = open_tab(c, @surface)
      edit(b, "summary", %{"summary" => "<p>old s2</p>"})
      assert words(stored(c)["summary"]) == ["old s2"]
    end

    test "#{surface}: a legacy body the store holds as blocks stays blocks", c do
      a = open_tab(c, @surface)
      edit(a, "body", %{"body" => "<p>body0 A1</p>"})
      assert words(stored(c)["body"]) == ["body0 A1"]
    end
  end
end
