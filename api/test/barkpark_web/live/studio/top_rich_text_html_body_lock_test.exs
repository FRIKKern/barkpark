defmodule BarkparkWeb.Studio.TopRichTextHtmlBodyLockTest do
  @moduledoc """
  task-bb19ab06ab1e87b2: a legacy `body` the store holds as an HTML string
  (`top_rich_text_html_body_test.exs`) was never held. A post typed on a
  value the store no longer holds, after a socket rejoin (#29054) or under
  a save that landed inside A's post (#28933), was written over B's body
  with no banner. It is now read under the lock as a block body is: B's
  string is kept, byte for byte, and A is held. It is never merged, so the
  store stays a string. One editor typing alone is never held.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])
  @paused ~s([data-test-id="doc-conflict-paused"])
  @line "Autosave is paused for body until you Save or Reload."

  setup %{conn: conn} do
    c = setup_doc(conn)
    put_body(c, "<p>body0</p>")
    c
  end

  defp put_body(c, html) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "body", html)
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

  # LiveViewTest always joins with `_mounts: 0`: the rejoin is the state
  # `TextConfirmed.loaded/1` gives a socket that mounted as one.
  defp rejoined(c, surface) do
    view = tab(c, surface)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :editor_rt_rejoin, MapSet.new(["doc[body]"])))
    end)

    view
  end

  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    value |> String.replace("&quot;", ~s(")) |> Jason.decode!() |> Map.put("v", 2)
  end

  # The digests the page takes from what the server pushed it.
  defp took(view, seen) do
    %{proxy: {ref, _topic, _}} = view

    receive do
      {^ref, {:push_event, "bp:form-confirmed", %{oks: oks}}} ->
        took(view, Map.update(seen, "ok", oks, &Map.merge(&1, oks)))
    after
      300 -> seen
    end
  end

  defp types(view, html, seen),
    do:
      view
      |> element("#editor-form")
      |> render_change(%{
        "_target" => ["doc[body]"],
        "doc" => %{"title" => "T0", "body" => html},
        "_bp_seen" => Jason.encode!(seen)
      })

  # A post with no `_bp_seen`, as `top_rich_text_race_test.exs` sends.
  defp body_post(view, html),
    do: send_post(view, "doc[body]", %{"doc" => %{"title" => "T0", "body" => html}})

  defp body(c), do: stored(c)["body"]

  # A typed " A1" and it landed; the socket dropped (the page keeps its
  # `_bp_seen` and its editor).
  defp typed_then_dropped(c, surface) do
    a = tab(c, surface)
    seen = took(a, page(a))
    types(a, "<p>body0 A1</p>", seen)
    assert body(c) == "<p>body0 A1</p>"
    seen = took(a, seen)
    GenServer.stop(a.pid, :normal)
    seen
  end

  defp held!(view, html) do
    assert html =~ "doc-conflict-banner", "A was not held"
    assert has_element?(view, @banner)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    for {label, b_html} <- [
          {"B adds a word", "<p>body0 A1 B5</p>"},
          {"B only bolds the text", "<p><strong>body0 A1</strong></p>"}
        ] do
      @b_html b_html

      test "#{surface} rejoin, #{label} while A's page is away: B's string kept, A held", c do
        seen = typed_then_dropped(c, @surface)
        put_body(c, @b_html)
        a2 = rejoined(c, @surface)
        html = types(a2, "<p>body0 A1 A7</p>", seen)
        assert body(c) == @b_html, "A's key was written over B's body"
        held!(a2, html)
        assert has_element?(a2, @paused, @line)
      end
    end

    test "#{surface} rejoin, nobody else saves: A's typing is written, never held", c do
      seen = typed_then_dropped(c, @surface)
      a2 = rejoined(c, @surface)
      html = types(a2, "<p>body0 A1 A7</p>", seen)
      assert body(c) == "<p>body0 A1 A7</p>"
      refute html =~ "doc-conflict-banner", "a lone editor was held"
      html = types(a2, "<p>body0 A1 A7 A8</p>", took(a2, seen))
      assert body(c) == "<p>body0 A1 A7 A8</p>"
      refute html =~ "doc-conflict-banner", "a lone editor was held"
    end

    for {label, b_html} <- [
          {"B rewrites the word", "<p>bodB</p>"},
          {"B only bolds the text", "<p><strong>body0</strong></p>"}
        ] do
      @b_html b_html

      test "#{surface} race, #{label} under A's post: B's string kept, A held", c do
        c = Map.put(c, :surface, @surface)
        {a, b} = {tab(c, @surface), tab(c, @surface)}

        html =
          inside(a, fn -> body_post(b, @b_html) end, fn -> body_post(a, "<p>body0 A</p>") end)

        assert body(c) == @b_html, "A's post was written over B's body"
        held!(a, html)
      end
    end

    test "#{surface} plain socket, one editor typing alone: every post written, never held", c do
      a = tab(c, @surface)

      for html <- ["<p>body0 A</p>", "<p>body0 AB</p>", "<p><em>body0</em> AB</p>"] do
        out = body_post(a, html)
        assert eventually(fn -> body(c) == html end)
        refute out =~ "doc-conflict-banner", "a lone editor was held"
      end
    end
  end
end
