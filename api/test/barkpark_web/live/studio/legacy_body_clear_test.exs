defmodule BarkparkWeb.Studio.LegacyBodyClearTest do
  @moduledoc """
  task-1dd8caaf8ce31309 (#29174 review, L1). A `body` with no format declared
  (legacy) that holds Portable Text, as the gyldendal twin's Sanity bodies
  do (decision 0007). A clears it, which stores `[]`, and types new words.
  A legacy body's `[]` read as an empty PortableDoc block list
  (`Forms.historical_body_blocks/1`): the save kept it and dropped A's
  words, with no banner. #29174 read `[]` as the field value only for a body
  the schema declares Portable Text. A legacy `[]` is now the field value
  too when the post carries words; a post with none keeps it as it is.

  Why `:legacy` and not the stored value: a legacy body declares no shape
  and its `[]` is either. The page drew the Classic editor for it (only
  that editor posts `doc[body]` as HTML), so A's words are written in the
  shape that editor posts. A body declared `portableDoc` keeps the
  PortableDoc reading and gets no Portable Text.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.PortableText
  alias Barkpark.Repo
  alias BarkparkWeb.PageSeen
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live

  setup %{conn: conn}, do: setup_doc(conn)

  defp body(c), do: stored(c)["body"]

  # The row itself, read back from the database.
  defp row_body(c) do
    Repo.get_by!(Document, doc_id: "drafts." <> c.id, type: c.type, dataset: "production").content[
      "body"
    ]
  end

  defp portable_doc!(c) do
    {:ok, schema} = Content.get_schema(c.type, "production")

    fields =
      Enum.map(schema.fields, fn
        %{"name" => "body"} = f -> Map.put(f, "format", "portableDoc")
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
  end

  # The value the Classic editor's hidden input holds, or nil when the page
  # draws no Classic editor for `body`.
  defp drawn_body(view) do
    case Regex.run(~r/<input[^>]*name="doc\[body\]"[^>]*value="([^"]*)"/, render(view)) do
      [_, v] -> v
      _ -> nil
    end
  end

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

  defp post(view, :autosave, doc, target) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => doc,
      "_bp_seen" => Jason.encode!(page(view))
    })
  end

  defp post(view, :save, doc, target) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(view.pid).socket.assigns

    render_hook(view, "save", %{
      "_target" => [target],
      "doc" => doc,
      "_bp_seen" => Jason.encode!(page(view)),
      "_bp_doc" => PostIdentity.value(ds, d.type, d.doc_id)
    })
  end

  defp types(view, how, html),
    do: post(view, how, %{"title" => "T0", "body" => html}, "doc[body]")

  for surface <- [:desk, :studio], how <- [:autosave, :save] do
    @surface surface
    @how how

    for clear <- ["<br>", "<p></p>", "<p><br></p>"] do
      @clear clear

      test "#{surface} #{how} L1: clear #{inspect(clear)}, then A types: written as Portable Text",
           c do
        put_body(c, [block("b1", "body0")])
        a = tab(c, @surface)
        types(a, @how, @clear)
        assert body(c) == [], "the clear did not store []: no test"

        html = types(a, @how, "<p>new A</p>")

        # Before: [] kept, A's words dropped, no banner.
        assert words(body(c)) == ["new A"], "A's words were not written: #{inspect(body(c))}"
        assert [%{"_type" => "block"}] = body(c)
        refute html =~ "doc-conflict-banner"
      end
    end

    test "#{surface} #{how}: a stored [] and a post with no words: [] kept", c do
      put_body(c, [])
      a = tab(c, @surface)

      post(a, @how, %{"title" => "T1", "body" => "<p><br></p>"}, "doc[title]")

      assert body(c) == []
      assert stored(c) |> Map.has_key?("body")
    end

    test "#{surface} #{how}: a stored [] and a title-only post: [] kept", c do
      put_body(c, [])
      a = tab(c, @surface)

      post(a, @how, %{"title" => "T1"}, "doc[title]")

      assert body(c) == []
    end

    test "#{surface} #{how}: each kind A types on a cleared body is a stored row of Portable Text, read again as one",
         c do
      put_body(c, [block("b1", "body0")])
      a = tab(c, @surface)
      types(a, @how, "<p></p>")
      assert row_body(c) == []

      # The page draws the Classic editor for the cleared body: A's words
      # are typed there.
      assert drawn_body(tab(c, @surface)) == ""

      typed =
        ~s(<h2>Head</h2><p><strong>bold</strong> and <a href="https://example.com/x">link</a></p>) <>
          "<ul><li>item</li></ul><blockquote>quote</blockquote>"

      types(a, @how, typed)
      written = row_body(c)

      assert PortableText.value?(written), "not Portable Text: #{inspect(written)}"

      assert Enum.map(written, &{&1["style"], &1["listItem"]}) |> Enum.take(3) == [
               {"h2", nil},
               {"normal", nil},
               {"normal", "bullet"}
             ]

      assert [%{"_type" => "link", "href" => "https://example.com/x"}] =
               Enum.at(written, 1)["markDefs"]

      assert Enum.any?(Enum.at(written, 1)["children"], &("strong" in &1["marks"]))
      assert words(written) |> Enum.take(3) == ["Head", "bold and link", "item"]

      # A second post edits one block; the others keep their keys.
      again = String.replace(PortableText.to_html(written), "item", "item A")
      types(a, @how, again)
      second = row_body(c)
      assert Enum.map(second, & &1["_key"]) == Enum.map(written, & &1["_key"])
      assert Enum.at(words(second), 2) == "item A"

      # A new tab draws the stored row as Portable Text, and a title-only
      # post leaves it as it is.
      GenServer.stop(a.pid, :normal)
      b = tab(c, @surface)
      refute render(b) =~ "invalid block"
      assert drawn_body(b) =~ "item A"
      post(b, @how, %{"title" => "T2"}, "doc[title]")
      assert row_body(c) == second
    end

    test "#{surface} #{how}: a body declared portableDoc stored [] gets no Portable Text", c do
      portable_doc!(c)
      put_body(c, [])
      a = tab(c, @surface)

      types(a, @how, "<p>new A</p>")

      body = row_body(c)

      refute PortableText.value?(body),
             "Portable Text written into a PortableDoc body: #{inspect(body)}"

      assert body == []
    end
  end
end
