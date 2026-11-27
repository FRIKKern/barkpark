defmodule BarkparkWeb.Studio.TopRichTextInFlightTest do
  @moduledoc """
  task-a368aa61eb491d9f (#29054 r2 review, R1): on a plain socket, B saves
  the body and A's socket takes it, but A's autosave was sent before the
  redraw reached A's page. `UnderLock.top/3` read the post against the row
  the socket last took (B's), so A's words were written over B's, with no
  banner.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn}, do: setup_doc(conn)

  defp h(words),
    do: Content.PortableText.to_html(Enum.with_index(words, &block("b#{&2 + 1}", &1)))

  defp body(c), do: words(stored(c)["body"])

  defp put_body(c, words) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" =>
            Map.put(doc.content, "body", Enum.with_index(words, &block("b#{&2 + 1}", &1)))
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

  # The page's `_bp_seen` as bp-array-focus.js keeps it (`PageSeen`). A
  # test keeps a copy to post later as an in-flight page would.
  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp types(view, words, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[body]"],
      "doc" => %{"title" => "T0", "body" => h(words)},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  # B saves the body; A's socket takes it (A's page has not drawn it yet).
  defp b_saves(c, surface, words) do
    b = tab(c, surface)
    types(b, words, page(b))
    assert eventually(fn -> body(c) == words end)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: A's post sent before B's save is drawn, one word: held, B's words stored",
         c do
      a = tab(c, @surface)
      seen = page(a)
      b_saves(c, @surface, ["body0 B5"])
      render(a)

      html = types(a, ["body0 A7"], seen)

      # On main: ["body0 A7"], no banner.
      assert body(c) == ["body0 B5"]
      assert html =~ "doc-conflict-banner"
      assert has_element?(a, @banner)
    end

    test "#{surface}: A's post sent before B's save is drawn, other blocks: both kept", c do
      put_body(c, ["body0", "second"])
      a = tab(c, @surface)
      seen = page(a)
      b_saves(c, @surface, ["body0", "second B5"])
      render(a)

      types(a, ["body0 A7", "second"], seen)

      # On main: ["body0 A7", "second"].
      assert eventually(fn -> body(c) == ["body0 A7", "second B5"] end)
    end

    test "#{surface}: a value rotated out of the log (9 frames since) is read as before, no crash",
         c do
      a = tab(c, @surface)
      seen = page(a)
      b = tab(c, @surface)

      # A's socket takes each frame on its own: two taken as one log one
      # value, and body0 would still be in the log.
      for i <- 1..9 do
        types(b, ["body0 B#{i}"], page(b))
        assert eventually(fn -> body(c) == ["body0 B#{i}"] end)
        assert eventually(fn -> form(a)["body"] =~ "body0 B#{i}" end)
      end

      log = :sys.get_state(a.pid).socket.assigns[:editor_rt_took]["doc[body]"]
      assert length(log) == 8
      assert is_binary(seen["ok"]["doc[body]"])
      refute List.keymember?(log, seen["ok"]["doc[body]"], 0)

      html = types(a, ["body0 A7"], seen)

      # The page's value is not in the log: read against the row the socket
      # took, as before this change.
      assert body(c) == ["body0 A7"]
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A's own posts before their confirm lands are written as typed",
         c do
      a = tab(c, @surface)
      seen = page(a)

      types(a, ["body0 A1"], seen)
      html = types(a, ["body0 A1 A2"], seen)

      assert body(c) == ["body0 A1 A2"]
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: a post typed after B's save was drawn is written", c do
      a = tab(c, @surface)
      _ = page(a)
      b_saves(c, @surface, ["body0 B5"])
      render(a)
      seen = page(a)

      types(a, ["body0 B5 A7"], seen)

      assert body(c) == ["body0 B5 A7"]
    end
  end
end
