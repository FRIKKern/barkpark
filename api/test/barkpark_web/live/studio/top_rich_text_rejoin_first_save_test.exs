defmodule BarkparkWeb.Studio.TopRichTextRejoinFirstSaveTest do
  @moduledoc """
  task-988edf908438d4a3 (#29259 review, T7b). After a rejoin where B saved
  while A's page was away, A's first post was a Save: `UnderLock.top/4`
  read no Save against the page's digest (a Save is what ends a rejoin
  hold), so A's words were written over B's with no banner. A Save with no
  rejoin hold open yet is read as an autosave is: held, with the banner. A
  Save on a held field still ends the hold and writes A's words.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])
  @paused ~s([data-test-id="doc-conflict-paused"])
  @line "Autosave is paused for body until you Save or Reload."

  setup %{conn: conn}, do: setup_doc(conn)

  defp h(words),
    do: Content.PortableText.to_html(Enum.with_index(words, &block("b#{&2 + 1}", &1)))

  defp body(c), do: words(stored(c)["body"])

  defp open_tab(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    # The load drew the wrapper: the page is sent the digest of what it
    # drew (not on main, which drew it only into `_bp_seen`'s first render).
    %{proxy: {ref, _topic, _}} = view

    receive do
      {^ref, {:push_event, "bp:form-confirmed", %{oks: %{"doc[body]" => _}}}} -> :ok
    after
      500 -> :ok
    end

    view
  end

  # LiveViewTest always joins with `_mounts: 0` (client_proxy.ex), so the
  # rejoin is the state `TextConfirmed.loaded/1` gives a socket that mounted
  # with `_mounts` above 0 (its own test below). A first mount's load sent
  # the page the digest of what it drew; a rejoin's does not.
  defp rejoined(c, surface) do
    view = open_tab(c, surface)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :editor_rt_rejoin, MapSet.new(["doc[body]"])))
    end)

    view
  end

  # The page's `_bp_seen` as the form drew it.
  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    value |> String.replace("&quot;", ~s(")) |> Jason.decode!() |> Map.put("v", 2)
  end

  # The digest the page takes after a post the store holds as it draws.
  defp confirmed(view, seen) do
    assert_push_event(view, "bp:form-confirmed", %{oks: %{"doc[body]" => _} = oks}, 2_000)
    Map.update(seen, "ok", oks, &Map.merge(&1, oks))
  end

  defp post(view, target, fields, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => Map.merge(%{"title" => "T0"}, fields),
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp types(view, words, seen), do: post(view, "doc[body]", %{"body" => h(words)}, seen)

  defp saves(view, words, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0", "body" => h(words)},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

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

  # A types " A1" and it lands; the page takes the confirmed digest (a
  # page that lost the confirm keeps the drawn one: a B save is held all
  # the same). Then the socket drops: the page keeps its `_bp_seen` and
  # its editor.
  defp typed_then_dropped(c, surface, confirm? \\ true) do
    a = open_tab(c, surface)
    seen = page(a)
    types(a, ["body0 A1"], seen)
    assert body(c) == ["body0 A1"]
    seen = if confirm?, do: confirmed(a, seen), else: seen
    GenServer.stop(a.pid, :normal)
    seen
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} T7b: B saves while A's page is away; A's first post is a Save: B kept, A held",
         c do
      seen = typed_then_dropped(c, @surface, false)
      put_body(c, ["body0 A1 B5"])
      a2 = rejoined(c, @surface)

      html = saves(a2, ["body0 A1 A7"], seen)

      # Before: ["body0 A1 A7"], written over B5 with no banner.
      assert body(c) == ["body0 A1 B5"], "A's Save wrote over B's: #{inspect(body(c))}"
      assert html =~ "doc-conflict-banner"
      assert has_element?(a2, @banner)
    end

    test "#{surface} T7b: then A's second Save ends the hold and writes A's words", c do
      seen = typed_then_dropped(c, @surface, false)
      put_body(c, ["body0 A1 B5"])
      a2 = rejoined(c, @surface)
      saves(a2, ["body0 A1 A7"], seen)
      assert body(c) == ["body0 A1 B5"]

      saves(a2, ["body0 A1 A7"], seen)

      assert body(c) == ["body0 A1 A7"]
      refute has_element?(a2, @paused)
    end

    # Controls, as on main.
    test "#{surface} control T7: a rejoin, nobody else saved; A's first post is a Save: written",
         c do
      seen = typed_then_dropped(c, @surface)
      a2 = rejoined(c, @surface)

      html = saves(a2, ["body0 A1 A7"], seen)

      assert body(c) == ["body0 A1 A7"]
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: a rejoin; B saved; an autosave holds, then a Save writes A's words",
         c do
      seen = typed_then_dropped(c, @surface, false)
      put_body(c, ["body0 A1 B5"])
      a2 = rejoined(c, @surface)
      types(a2, ["body0 A1 A7"], seen)
      assert body(c) == ["body0 A1 B5"]
      assert has_element?(a2, @paused, @line)

      saves(a2, ["body0 A1 A7"], seen)

      assert body(c) == ["body0 A1 A7"]
      refute has_element?(a2, @paused)
    end

    test "#{surface} control: a first mount; B saved before A's Save on a fresh page: written",
         c do
      put_body(c, ["body0 B5"])
      a = open_tab(c, @surface)

      saves(a, ["body0 B5 A1"], page(a))

      assert body(c) == ["body0 B5 A1"]
    end
  end
end
