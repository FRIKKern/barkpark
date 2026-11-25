defmodule BarkparkWeb.Studio.ObjectRichTextHeldAgainTest do
  # task-4dbb75a6eb9ceeea (#28801 review): A is held once (B2 clashed in
  # p1), and posts again before drawing the view. B3 changes p1 again and
  # p3. Saved inside that post (`:under_lock`, `b_saves_inside/4`), B3 was
  # never shown: `UnderLock.acts/4` skipped a post `split/3` had held, so
  # the hold's view came from the old store, and A typing on it erased
  # B3's "x y" with no banner. `:control`: B3 saves before A's post.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live
  @banner "Someone else rewrote"

  setup %{conn: conn}, do: setup_doc(conn)

  defp pushes(view, acc \\ []) do
    {ref, _, _} = view.proxy

    receive do
      {^ref, {:push_event, "bp:rt-remote", %{values: %{"doc[meta].rt" => v}}}} ->
        pushes(view, [v | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp paras(html), do: Regex.scan(~r{<p>(.*?)</p>}, html || "") |> Enum.map(&Enum.at(&1, 1))
  defp h(ws), do: Enum.map_join(ws, &"<p>#{&1}</p>")
  defp rt(c), do: words(stored(c)["meta"]["rt"])

  defp b_then(mode, a, b, c, b_words, a_post) do
    case mode do
      :under_lock ->
        b_saves_inside(a, b, h(b_words), a_post)

      :control ->
        send_post(b, "doc[meta].rt", %{"doc[meta].label" => "l0", "doc[meta].rt" => h(b_words)})
        assert eventually(fn -> rt(c) == b_words end)
        a_post.()
    end
  end

  for surface <- [:desk, :studio], mode <- [:control, :under_lock] do
    test "#{surface} #{mode}: two holds in a row; B3 saved under A's second post shows in the view, and typing on keeps it",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      b_saves_rt(b, c, h(["one two", "three four", "x"]), ["one two", "three four", "x"])
      page = Enum.reduce(pushes(a), page(), &got(&2, &1, true))
      _ = pushes(b)

      # B1 waits on A's page (A typing).
      b_saves_rt(b, c, h(["one two", "THREE four", "x"]), ["one two", "THREE four", "x"])
      page = Enum.reduce(pushes(a), page, &got(&2, &1, false))

      # First hold: B2 clashes with A in p1.
      html =
        b_then(unquote(mode), a, b, c, ["one twB", "THREE four", "x"], fn ->
          post_rt(a, h(["one twoA", "three four", "x"]), seen(page))
        end)

      assert html =~ @banner
      page = Enum.reduce(pushes(a), page, &got(&2, &1, false))
      _ = pushes(b)

      # Second hold: B3 changes p1 again and p3; A posts again, not drawn.
      html =
        b_then(unquote(mode), a, b, c, ["one TWB", "THREE four", "x y"], fn ->
          post_rt(a, h(["one twoAA", "three four", "x"]), seen(page))
        end)

      assert html =~ @banner
      assert rt(c) == ["one TWB", "THREE four", "x y"]
      ps = pushes(a)
      page = Enum.reduce(ps, page, &got(&2, &1, true))
      view = paras((List.last(ps) || %{})[:html])

      # On main (`:under_lock`): ["one twoAA", "THREE four", "x"], B3's p3 gone.
      assert view == ["one twoAA", "THREE four", "x y"]

      post_rt(a, view |> List.update_at(0, &(&1 <> "Z")) |> h(), seen(page))
      assert rt(c) == ["one twoAAZ", "THREE four", "x y"]
    end

    test "#{surface} #{mode}: held, A posts the shown view as it is; B3 saved under that post shows in the view, and typing on keeps it",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      b_saves_rt(b, c, h(["one two", "three four", "x"]), ["one two", "three four", "x"])
      page = Enum.reduce(pushes(a), page(), &got(&2, &1, true))
      _ = pushes(b)

      html =
        b_then(unquote(mode), a, b, c, ["one twB", "three four", "x"], fn ->
          post_rt(a, h(["one twoA", "three four", "x"]), seen(page))
        end)

      assert html =~ @banner
      ps = pushes(a)
      page = Enum.reduce(ps, page, &got(&2, &1, true))
      shown = paras(List.last(ps)[:html])
      _ = pushes(b)

      # A's page posts the view it drew, unchanged; B3 changes p3.
      html =
        b_then(unquote(mode), a, b, c, ["one twB", "three four", "x y"], fn ->
          post_rt(a, h(shown), seen(page))
        end)

      assert html =~ @banner
      assert rt(c) == ["one twB", "three four", "x y"]
      ps = pushes(a)
      page = Enum.reduce(ps, page, &got(&2, &1, true))
      view = paras((List.last(ps) || %{})[:html])
      assert List.last(view) == "x y"

      post_rt(a, view |> List.update_at(1, &(&1 <> "Z")) |> h(), seen(page))
      assert List.last(rt(c)) == "x y"
    end
  end
end
