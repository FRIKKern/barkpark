defmodule BarkparkWeb.Studio.TopRichTextRedrawPointsTest do
  @moduledoc """
  task-9e48bd006a46033f (#29054 r2 review, point 3): a press that reads the
  form again from the store (`Shared.rebuild_panes/1`) draws a top-level
  rich text wrapper anew when the store's value moved, and the page shows
  the store. Each of these presses did not send the page the drawn digest
  (`TextConfirmed.redrawn/2`), so the page kept the digest of the value it
  showed before. After a rejoin, A's next key, typed on what the page shows,
  was held as typed on a value the store no longer holds: a false hold.

  B's save lands inside A's press (`inside/3`), after A's socket starts
  the press and before it reads the row, so the press draws B's value and
  B's frame that follows changes nothing on A's socket.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  @banner "doc-conflict-banner"

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
    view
  end

  # LiveViewTest always joins with `_mounts: 0`: the rejoin is the state
  # `TextConfirmed.loaded/1` gives a socket that mounted as one.
  defp rejoined(c, surface) do
    view = open_tab(c, surface)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :editor_rt_rejoin, MapSet.new(["doc[body]"])))
    end)

    view
  end

  # The page's `_bp_seen` as bp-array-focus.js keeps it (`PageSeen`).
  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp post(view, target, fields, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => Map.merge(%{"title" => "T0"}, fields),
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp gen(view), do: :sys.get_state(view.pid).socket.assigns.editor_form_gen

  # A presses; B's body save lands inside the press. The press drew B's
  # body (a new form generation). Then A's socket drops, the page rejoins,
  # and A types on what it shows, alone: written, never held.
  defp redrawn_then_rejoin(c, surface, a, press, b_save \\ nil) do
    page(a)
    b = open_tab(c, surface)
    b_seen = page(b)
    was = gen(a)

    b_save =
      b_save || fn -> post(b, "doc[body]", %{"body" => h(["body0 B"])}, b_seen) end

    inside(a, b_save, fn -> press.(a) end)
    assert body(c) == ["body0 B"]
    render(a)
    assert gen(a) != was, "the press did not draw the form anew: no test"
    seen = page(a)

    GenServer.stop(a.pid, :normal)
    a2 = rejoined(c, surface)
    html = post(a2, "doc[body]", %{"body" => h(["body0 B A"])}, seen)

    assert body(c) == ["body0 B A"], "A, alone, typing on the drawn body was held"
    refute html =~ @banner
  end

  test "studio: Show more on the desk list draws B's body; after a rejoin A is not held", c do
    a = open_tab(c, :studio)

    redrawn_then_rejoin(c, :studio, a, fn a ->
      render_click(a, "desk-list-more", %{"type" => c.type})
    end)
  end

  test "studio: a sort pick draws B's body; after a rejoin A is not held", c do
    a = open_tab(c, :studio)

    redrawn_then_rejoin(c, :studio, a, fn a ->
      render_click(a, "select-sort", %{"type" => c.type, "sort" => ""})
    end)
  end

  test "studio: Publish draws B's body; after a rejoin A is not held", c do
    a = open_tab(c, :studio)
    redrawn_then_rejoin(c, :studio, a, &EditorPost.press(&1, "publish"))
  end

  test "studio: Unpublish draws B's body; after a rejoin A is not held", c do
    {:ok, _} = Content.publish_document(c.id, c.type, "production")
    a = open_tab(c, :studio)
    redrawn_then_rejoin(c, :studio, a, &EditorPost.press(&1, "unpublish"))
  end

  test "studio: a bulk Publish of the open document draws B's body; after a rejoin A is not held",
       c do
    a = open_tab(c, :studio)

    redrawn_then_rejoin(c, :studio, a, fn a ->
      :sys.replace_state(a.pid, fn state ->
        update_in(state.socket.assigns, &Map.put(&1, :selected_doc_ids, MapSet.new([c.id])))
      end)

      render_click(a, "bulk-publish", %{})
    end)
  end

  test "studio control: Show more with no other save draws nothing anew; after a rejoin A is not held",
       c do
    a = open_tab(c, :studio)
    seen = page(a)
    was = gen(a)
    render_click(a, "desk-list-more", %{"type" => c.type})
    assert gen(a) == was
    seen = Map.merge(seen, page(a))

    GenServer.stop(a.pid, :normal)
    a2 = rejoined(c, :studio)
    html = post(a2, "doc[body]", %{"body" => h(["body0 A"])}, seen)

    assert body(c) == ["body0 A"]
    refute html =~ @banner
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: a Save that holds the title draws B's body; after a rejoin A is not held",
         c do
      a = open_tab(c, @surface)
      b = open_tab(c, @surface)
      b_seen = page(b)

      b_save = fn ->
        post(b, "doc[title]", %{"title" => "T B", "body" => h(["body0"])}, b_seen)
        post(b, "doc[body]", %{"title" => "T B", "body" => h(["body0 B"])}, b_seen)
      end

      redrawn_then_rejoin(
        c,
        @surface,
        a,
        fn a ->
          html =
            a
            |> element("#editor-form")
            |> render_submit(%{
              "doc" => %{"title" => "T A", "body" => h(["body0"])},
              "_bp_seen" => Jason.encode!(page(a))
            })

          assert html =~ @banner, "the Save did not hold the title: no test"
        end,
        b_save
      )
    end
  end
end
