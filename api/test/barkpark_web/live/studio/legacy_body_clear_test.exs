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
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.PageSeen
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @moduletag :studio_live

  setup %{conn: conn}, do: setup_doc(conn)

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
  end
end
