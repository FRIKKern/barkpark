defmodule BarkparkWeb.Studio.ObjectRichTextBannerCapTest do
  # task-f3594c6613f4663e (#28801 review): a clash shown as mine whole lists
  # theirs' blocks the view does not have in the banner, at most 5. Seed 52
  # of the review's generator: theirs' sixth such block ("iota xi tau t2")
  # was in neither the view nor the banner, and A typing on the view saved
  # mine over it with no word.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  setup %{conn: conn}, do: setup_doc(conn)

  @base [
    "lam alpha omi",
    "psi phi eta",
    "ups omg zeta",
    "nu eps sig",
    "delta rho chi",
    "iota xi tau"
  ]
  @mine [
    "lam alpha omi",
    "psi",
    "phi eta",
    "ups omg zeta",
    "nu eps sig",
    "delta rho chi m2",
    "iota xi tau"
  ]
  @theirs [
    "lam",
    "alpha omi",
    "psi phi eta",
    "ups omg zeta",
    "nu eps sig t1",
    "DELTA RHO CHI",
    "iota xi tau t2"
  ]

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

  defp theirs_shown(html),
    do:
      Regex.scan(~r{<blockquote[^>]*data-version="theirs"[^>]*>(.*?)</blockquote>}s, html)
      |> Enum.map(&String.trim(Enum.at(&1, 1)))

  for surface <- [:desk, :studio] do
    test "#{surface}: a clash with more of theirs' blocks than the banner shows; typing on the view never drops one silently",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      b_saves_rt(b, c, h(@base), @base)
      page = Enum.reduce(pushes(a), page(), &got(&2, &1, true))
      _ = pushes(b)

      # B saves theirs; A, typing, has not drawn it, and posts mine.
      b_saves_rt(b, c, h(@theirs), @theirs)
      page = Enum.reduce(pushes(a), page, &got(&2, &1, false))
      html = post_rt(a, h(@mine), seen(page))
      ps = pushes(a)
      page = Enum.reduce(ps, page, &got(&2, &1, true))
      view = paras(List.last(ps)[:html])
      shown = theirs_shown(html)

      # A draws the view and types on it.
      post_rt(a, view |> List.update_at(0, &(&1 <> "Z")) |> h(), seen(page))
      stored = words(stored(c)["meta"]["rt"])

      lost =
        for t <- @theirs,
            t not in @base,
            t not in view,
            t not in shown,
            t not in stored,
            do: t

      assert lost == [],
             "theirs' #{inspect(lost)} dropped with no word: view=#{inspect(view)} banner=#{inspect(shown)} stored=#{inspect(stored)} html_more=#{html =~ "more"}"
    end
  end
end
