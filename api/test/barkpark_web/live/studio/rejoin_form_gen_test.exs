defmodule BarkparkWeb.Studio.RejoinFormGenTest do
  @moduledoc """
  task-b656db94cc1dbd17: a widget's wrapper id carries the form generation
  once it is above 0, and a new socket starts at 0. A page whose form had
  been drawn again (another editor's save) rejoined with other wrapper ids:
  LiveView put an editor drawn from the store in place of the page's, and
  the words typed while the socket was down were gone, with no banner
  (#29054 rig, case d).

  The page sends its form's document and generation on each join
  (`_bp_form`); a rejoin draws that generation for the document it loads,
  so the wrapper ids are the page's. The page's value never picks a
  document: a form named for another one is ignored.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias BarkparkWeb.Studio.StudioLive.PostIdentity
  alias BarkparkWeb.Studio.StudioLive.RejoinForm

  @moduletag :studio_live

  setup %{conn: conn}, do: setup_doc(conn)

  defp h(text), do: "<p>#{text}</p>"

  defp doc_path(c, :desk, id), do: "#{c.root}/_desk/#{c.type};#{id}"
  defp doc_path(c, :studio, id), do: "#{c.root}/#{c.type}/#{id}"

  defp list_path(c, :desk), do: "#{c.root}/_desk/#{c.type}"
  defp list_path(c, :studio), do: "#{c.root}/#{c.type}"

  defp tab(c, surface) do
    {:ok, view, _html} = live(c.conn, doc_path(c, surface, c.id))
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  # The body's wrapper id, as the page has it.
  defp body_wrap(view) do
    [id] = Regex.run(~r/id="(bp-rt-wrap-body-[^"]+)"/, render(view), capture: :all_but_first)
    id
  end

  defp gen(view), do: :sys.get_state(view.pid).socket.assigns[:editor_form_gen]

  defp doc_value(c, id), do: PostIdentity.value("production", c.type, id)

  # The mount's flags (`_mounts` > 0 and `_bp_form`, which LiveViewTest
  # cannot send: it joins with `_mounts: 0`) as the rejoin's first patch
  # reads them: the document it loads is the page's.
  defp rejoined(c, surface, page_form) do
    {:ok, view, _} = live(c.conn, list_path(c, surface))

    flags =
      %{editor_rejoined?: true, editor_rejoin_form: page_form}
      |> Map.merge(if surface == :desk, do: %{desk_rejoin?: true}, else: %{})

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.merge(&1, flags))
    end)

    render_patch(view, doc_path(c, surface, c.id))
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  # A's clean page takes B's save: its form is drawn again, at gen 1.
  defp page_at_gen_1(c, surface) do
    a = tab(c, surface)
    b = tab(c, surface)
    send_post(b, "doc[body]", %{"doc" => %{"title" => "T0", "body" => h("body0 B4")}})
    assert eventually(fn -> words(stored(c)["body"]) == ["body0 B4"] end)
    assert eventually(fn -> gen(a) == 1 end)
    assert body_wrap(a) =~ ~r/-g1$/
    a
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: a page drawn at gen 1 rejoins with its own wrapper ids, and its next key is written",
         c do
      a = page_at_gen_1(c, @surface)
      page = {doc_value(c, c.id), 1}
      wrap = body_wrap(a)
      GenServer.stop(a.pid, :normal)

      a2 = rejoined(c, @surface, page)

      assert body_wrap(a2) == wrap,
             "the rejoin drew other wrapper ids: the page's editor is replaced"

      # A typed " A7" while the socket was down: the editor kept it, and the
      # next key posts it.
      send_post(a2, "doc[body]", %{"doc" => %{"title" => "T0", "body" => h("body0 B4 A7 A8")}})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 B4 A7 A8"] end)
    end

    test "#{surface}: a page form named for another document draws gen 0", c do
      a2 = rejoined(c, @surface, {doc_value(c, c.id <> "-link"), 7})
      assert gen(a2) in [nil, 0]
      refute body_wrap(a2) =~ ~r/-g\d+$/
      # The URL's document is loaded, never the one the page named.
      assert PostIdentity.of(:sys.get_state(a2.pid).socket) == doc_value(c, c.id)
    end

    test "#{surface}: a rejoin with no page form draws gen 0", c do
      a2 = rejoined(c, @surface, nil)
      assert gen(a2) in [nil, 0]
      refute body_wrap(a2) =~ ~r/-g\d+$/
    end

    test "#{surface}: a first load never takes a page form", c do
      {:ok, view, _} = live(c.conn, list_path(c, @surface))

      :sys.replace_state(view.pid, fn state ->
        update_in(
          state.socket.assigns,
          &Map.put(&1, :editor_rejoin_form, {doc_value(c, c.id), 4})
        )
      end)

      render_patch(view, doc_path(c, @surface, c.id))
      render_async(view, 5_000)
      assert eventually(fn -> has_element?(view, "#editor-form") end)
      refute body_wrap(view) =~ ~r/-g\d+$/
    end
  end

  test "the page's form is read only from a rejoin's connect params, as a bounded integer" do
    doc = ~s(["production","post","p1"])
    rejoin = %{"_mounts" => 1}

    assert RejoinForm.from_params(Map.put(rejoin, "_bp_form", %{"doc" => doc, "gen" => "3"})) ==
             {doc, 3}

    assert RejoinForm.from_params(Map.put(rejoin, "_bp_form", %{"doc" => doc, "gen" => 3})) ==
             {doc, 3}

    for gen <- ["-1", "100001", "3x", "", %{"a" => 1}, [1], nil, 1.5] do
      assert RejoinForm.from_params(Map.put(rejoin, "_bp_form", %{"doc" => doc, "gen" => gen})) ==
               nil,
             "took gen #{inspect(gen)}"
    end

    assert RejoinForm.from_params(%{"_mounts" => 0, "_bp_form" => %{"doc" => doc, "gen" => "3"}}) ==
             nil

    assert RejoinForm.from_params(Map.put(rejoin, "_bp_form", %{"doc" => 5, "gen" => "3"})) == nil
    assert RejoinForm.from_params(Map.put(rejoin, "_bp_form", "x")) == nil
    assert RejoinForm.from_params(nil) == nil
    assert RejoinForm.from_params(false) == nil
  end
end
