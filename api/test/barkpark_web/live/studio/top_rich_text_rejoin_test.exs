defmodule BarkparkWeb.Studio.TopRichTextRejoinTest do
  @moduledoc """
  task-fe9d8741f0641f97, top-level rich text (#28933 review): the wrapper of
  a top-level rich text editor is phx-update="ignore" and has the same id
  after a socket rejoin, so the page keeps the editor it had while the new
  socket reads the new store. A save B made while A's page was away was
  written over by A's next key, with no banner.

  The page keeps the digest of the value the server last confirmed it shows
  (`TextConfirmed`, `"ok"` in `_bp_seen`). On a socket that mounted as a
  rejoin (`_mounts` > 0), a post whose digest is the store's is read as
  before; one whose digest differs is held, with the banner and the paused
  line, until a Save or Reload.
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

  test "a socket that mounted as a rejoin reads each top-level rich text against the page's digest" do
    alias BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed

    schema = %{
      fields: [%{"name" => "body", "type" => "richText"}, %{"name" => "t", "type" => "string"}]
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, editor_rejoined?: true, editor_schema: schema}
    }

    loaded = TextConfirmed.loaded(socket)
    assert loaded.assigns.editor_rt_rejoin == MapSet.new(["doc[body]"])
    assert loaded.assigns.editor_rejoined? == false
    assert BarkparkWeb.Studio.DeskLive.rejoin?(%{"_mounts" => 1})
    refute BarkparkWeb.Studio.DeskLive.rejoin?(%{"_mounts" => 0})

    # The next load (another document) is a first draw of its own.
    assert TextConfirmed.loaded(loaded).assigns.editor_rt_rejoin == MapSet.new()
  end

  # The mount's flag (`_mounts` > 0, which LiveViewTest cannot send) as the
  # first patch after it reads it: the document that patch loads is read
  # against the page's digest; one opened later is drawn anew.
  defp flagged(view, assigns) do
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.merge(&1, assigns))
    end)
  end

  defp rejoin_set(view), do: :sys.get_state(view.pid).socket.assigns[:editor_rt_rejoin]

  test "desk: the document a rejoin's first patch loads is read against the page's digest", c do
    {:ok, view, _} = live(c.conn, "#{c.root}/_desk/#{c.type}")
    flagged(view, %{desk_rejoin?: true, editor_rejoined?: true})
    render_patch(view, "#{c.root}/_desk/#{c.type};#{c.id}")
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    assert rejoin_set(view) == MapSet.new(["doc[body]"])
  end

  test "desk: a rejoin whose first patch loads no document: the one opened next is drawn anew",
       c do
    {:ok, view, _} = live(c.conn, "#{c.root}/_desk/#{c.type}")
    flagged(view, %{desk_rejoin?: true, editor_rejoined?: true})
    render_patch(view, "#{c.root}/_desk/#{c.type}")
    render_patch(view, "#{c.root}/_desk/#{c.type};#{c.id}")
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    assert rejoin_set(view) == MapSet.new()
  end

  test "studio: the document a rejoin's first patch loads is read against the page's digest", c do
    {:ok, view, _} = live(c.conn, "#{c.root}/#{c.type}")
    flagged(view, %{editor_rejoined?: true})
    render_patch(view, "#{c.root}/#{c.type}/#{c.id}")
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    assert rejoin_set(view) == MapSet.new(["doc[body]"])
  end

  for surface <- [:desk, :studio] do
    test "#{surface}: a rejoin after A's own autosave, nobody else saving: A's typing is written, no banner",
         c do
      seen = typed_then_dropped(c, unquote(surface))
      a2 = rejoined(c, unquote(surface))

      html = types(a2, ["body0 A1 A7"], seen)
      assert body(c) == ["body0 A1 A7"]
      refute html =~ "doc-conflict-banner"

      types(a2, ["body0 A1 A7 A8"], seen)
      assert body(c) == ["body0 A1 A7 A8"]
    end

    test "#{surface}: B saves while A's page is away: held; typing on stays held, another field autosaves, a Save writes and autosave resumes",
         c do
      seen = typed_then_dropped(c, unquote(surface), false)
      put_body(c, ["body0 A1 B5"])
      a2 = rejoined(c, unquote(surface))

      # On main: A's words were written over B5, with no banner.
      for words <- [["body0 A1 A7"], ["body0 A1 A7 A8"]] do
        types(a2, words, seen)
        assert body(c) == ["body0 A1 B5"]
        assert has_element?(a2, @banner)
        assert has_element?(a2, @paused, @line)
      end

      post(a2, "doc[title]", %{"title" => "T1", "body" => h(["body0 A1 A7 A8"])}, seen)
      {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
      assert doc.title == "T1"
      assert body(c) == ["body0 A1 B5"]
      assert has_element?(a2, @paused, @line)

      saves(a2, ["body0 A1 A7 A8"], seen)
      assert body(c) == ["body0 A1 A7 A8"]
      refute has_element?(a2, @paused)
      seen = confirmed(a2, seen)

      types(a2, ["body0 A1 A7 A8 A9"], seen)
      assert body(c) == ["body0 A1 A7 A8 A9"]
      refute has_element?(a2, @banner)
    end

    test "#{surface}: B saves while A's page is away; Reload takes B's and ends the pause", c do
      seen = typed_then_dropped(c, unquote(surface), false)
      put_body(c, ["body0 A1 B5"])
      a2 = rejoined(c, unquote(surface))
      types(a2, ["body0 A1 A7"], seen)
      assert has_element?(a2, @paused, @line)

      a2 |> element(~s([data-test-id="doc-conflict-reload"])) |> render_click()
      refute has_element?(a2, @banner)
      assert body(c) == ["body0 A1 B5"]
      seen = confirmed(a2, seen)

      types(a2, ["body0 A1 B5 A9"], seen)
      assert body(c) == ["body0 A1 B5 A9"]
    end

    test "#{surface}: a first mount is read as before: no digest check", c do
      put_body(c, ["body0 B5"])
      a = open_tab(c, unquote(surface))
      # A page with no digest at all, on a socket that did not rejoin.
      types(a, ["body0 B5 A1"], %{"v" => 2})
      assert body(c) == ["body0 B5 A1"]
    end
  end
end
