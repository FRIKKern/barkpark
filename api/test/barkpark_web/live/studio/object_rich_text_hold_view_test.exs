defmodule BarkparkWeb.Studio.ObjectRichTextHoldViewTest do
  # task-77c9532e1e04907b (#28792 review): B1 changes p2 and waits on A's
  # page; B2 then clashes with A in p1. A's view after the hold dropped
  # B1's p2 (the merge showed mine whole when B's change ran across p1 and
  # p2), so A typing on the view took THREE out, with no banner.
  #
  # `:control`: B2 saves before A's post. `:under_lock`: B2 saves inside it
  # (`b_saves_inside/4`, task-00c56c6a88ed0b8f).
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

  for surface <- [:desk, :studio], mode <- [:control, :under_lock] do
    test "#{surface} #{mode}: B1 waits in p2, B2 clashes in p1; A posts before drawing, then types on the view: THREE stays",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      b_saves_rt(b, c, "<p>one two</p><p>three four</p><p>x</p>", ["one two", "three four", "x"])
      page = Enum.reduce(pushes(a), page(), &got(&2, &1, true))
      _ = pushes(b)

      # B1 waits on A's page (A typing).
      b_saves_rt(b, c, "<p>one two</p><p>THREE four</p><p>x</p>", ["one two", "THREE four", "x"])
      page = Enum.reduce(pushes(a), page, &got(&2, &1, false))

      b2 = "<p>one twB</p><p>THREE four</p><p>x</p>"
      a1 = fn -> post_rt(a, "<p>one twoA</p><p>three four</p><p>x</p>", seen(page)) end

      {html, page} =
        case unquote(mode) do
          :under_lock ->
            {b_saves_inside(a, b, b2, a1), page}

          :control ->
            send_post(b, "doc[meta].rt", %{"doc[meta].label" => "l0", "doc[meta].rt" => b2})

            assert eventually(fn ->
                     words(stored(c)["meta"]["rt"]) == ["one twB", "THREE four", "x"]
                   end)

            page = Enum.reduce(pushes(a), page, &got(&2, &1, false))
            {a1.(), page}
        end

      assert html =~ @banner
      ps = pushes(a)
      assert [_ | _] = ps
      assert Enum.at(paras(List.last(ps)[:html]), 1) == "THREE four"
      page = Enum.reduce(ps, page, &got(&2, &1, false))

      # A types on before drawing the view: held again, the view keeps THREE.
      html = post_rt(a, "<p>one twoAA</p><p>three four</p><p>x</p>", seen(page))
      assert html =~ @banner
      ps = pushes(a)
      view = paras((List.last(ps) || %{})[:html])
      assert view == ["one twoAA", "THREE four", "x"]
      page = Enum.reduce(ps, page, &got(&2, &1, true))

      # A draws the view at idle and types on it: B1's THREE stays.
      typed = view |> List.update_at(2, &(&1 <> "Z")) |> Enum.map_join(&"<p>#{&1}</p>")
      post_rt(a, typed, seen(page))
      assert words(stored(c)["meta"]["rt"]) == ["one twoAA", "THREE four", "xZ"]
    end
  end
end
