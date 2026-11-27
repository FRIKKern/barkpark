defmodule BarkparkWeb.Studio.TopRichTextHoldRawStringTest do
  @moduledoc """
  task-d9ffbd2e6639496b (#29144 review). A top-level rich text the store
  holds as an HTML string: a legacy `body`, or a Portable Text field holding
  one. B adds an image under A's post, and A is held on B's string. C then
  adds an iframe under the lock of A's next post, typed on the hold's view.
  The resolve read the post against the hold's `theirs`, kept as blocks
  (`UnderLock.html_hold/3`), so `HtmlBody.exact?/2` fell back to the
  drawing, which drops the iframe: B's string read as C's, and A's post was
  written over C's with no banner. A Portable Text field holding a string
  had the reverse: its string never matched the blocks, so typing on the
  hold's view stayed held with nobody else saving. The hold now keeps B's
  string as stored.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  @b ~s(<p>body0</p><img src="x.png">)
  @c ~s(<p>body0</p><img src="x.png"><iframe src="https://z"></iframe>)

  setup %{conn: conn}, do: {:ok, setup_doc(conn)}

  defp body(c), do: stored(c)["body"]

  defp put_body(c, value) do
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

  # The body field as a Portable Text field holding a string.
  defp portable_text!(c) do
    {:ok, schema} = Content.get_schema(c.type, "production")

    fields =
      Enum.map(schema.fields, fn
        %{"name" => "body"} = f -> Map.put(f, "format", "portableText")
        f -> f
      end)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => c.type, "title" => "Rich", "visibility" => "public", "fields" => fields},
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

  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp types(view, html, seen),
    do:
      view
      |> element("#editor-form")
      |> render_change(%{
        "_target" => ["doc[body]"],
        "doc" => %{"title" => "T0", "body" => html},
        "_bp_seen" => Jason.encode!(seen)
      })

  defp under(c, a, value, post),
    do: inside(a, fn -> Task.await(Task.async(fn -> put_body(c, value) end)) end, post)

  # A held on B's string.
  defp held_on_b(c, surface) do
    put_body(c, "<p>body0</p>")
    a = tab(c, surface)
    seen = page(a)
    html = under(c, a, @b, fn -> types(a, "<p>body0 A</p>", seen) end)
    assert html =~ "doc-conflict-banner", "A was not held on B's string: no test"
    assert body(c) == @b
    a
  end

  for surface <- [:desk, :studio], kind <- [:legacy, :portable_text] do
    @surface surface
    @kind kind

    test "#{surface} #{kind}: C adds an iframe under A's post on the hold view: C kept, A held",
         c do
      if @kind == :portable_text, do: portable_text!(c)
      a = held_on_b(c, @surface)

      html = under(c, a, @c, fn -> types(a, "<p>body0 A</p><p>A2</p>", page(a)) end)

      # On main: A's post was written over C's string, no banner.
      assert body(c) == @c, "A's post was written over C's string: #{inspect(body(c))}"
      assert html =~ "doc-conflict-banner", "A was not held"
    end

    test "#{surface} #{kind} control: nobody else saves; A types on the hold view: written", c do
      if @kind == :portable_text, do: portable_text!(c)
      a = held_on_b(c, @surface)

      types(a, "<p>body0 A</p><p>A2</p>", page(a))

      # A legacy body stores the posted HTML; a Portable Text field, blocks.
      assert body(c) == "<p>body0 A</p><p>A2</p>" or words(body(c)) == ["body0 A", "A2"],
             "A's post on the hold view was not written: #{inspect(body(c))}"
    end
  end
end
