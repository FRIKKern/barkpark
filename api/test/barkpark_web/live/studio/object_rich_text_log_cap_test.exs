defmodule BarkparkWeb.Studio.ObjectRichTextLogCapTest do
  @moduledoc """
  task-d6870fd34d7769b3 (#28755 review, should fix 1): `RichTextRemote`
  keeps 8 changes per rich text. With more of B's saves waiting on A's
  page, the oldest was dropped and A's post was read against a base A never
  had: B's oldest change went with no banner. A trimmed log keeps the
  oldest base; a post that saw a dropped change, but not all of them, is
  held.
  """
  use BarkparkWeb.ConnCase, async: false

  import BarkparkWeb.ObjectRichText

  setup %{conn: conn}, do: setup_doc(conn)

  @blocks for i <- 1..10, do: "w#{i} alpha beta"

  defp rt(blocks), do: Enum.map_join(blocks, &"<p>#{&1}</p>")

  # B's save `k`: an " x" on w1..wk.
  defp with_x(k),
    do:
      Enum.with_index(@blocks, 1) |> Enum.map(fn {b, i} -> if i <= k, do: b <> " x", else: b end)

  test "10 of B's saves waiting on A's page: A's post keeps all of them, no banner", c do
    a = open(c)
    b = open(c)
    b_saves_rt(b, c, rt(["one two" | @blocks]), ["one two" | @blocks])
    page = got(page(), next_push(a), false)

    page =
      Enum.reduce(1..9, page, fn k, page ->
        b_saves_rt(b, c, rt(["one two" | with_x(k)]), ["one two" | with_x(k)])
        got(page, next_push(a), false)
      end)

    html = post_rt(a, "<p>one twoA</p>", seen(page))

    # Read against B's third save, the oldest the log kept, B's paragraphs
    # and w1's x read as A's deletes and were lost with no banner.
    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one twoA" | with_x(9)] end)
    refute html =~ "Someone else rewrote"
  end

  test "A saw B's first save, then B took it back and 8 more wait: held, B's value stored", c do
    b = open(c)
    b_saves_rt(b, c, rt(["one two" | @blocks]), ["one two" | @blocks])
    a = open(c)

    b_saves_rt(b, c, rt(["one two" | with_x(1)]), ["one two" | with_x(1)])
    page = got(page(), next_push(a), true)

    # B takes w1's x back, then adds an x to w2..w9, one save each.
    page =
      Enum.reduce(1..9, page, fn k, page ->
        blocks = @blocks |> with_x_from(2, k)
        b_saves_rt(b, c, rt(["one two" | blocks]), ["one two" | blocks])
        got(page, next_push(a), false)
      end)

    html = post_rt(a, rt(["one twoA" | with_x(1)]), seen(page))

    # The change A drew and B's take-back of it are both folded, so no base
    # fits A's post: held. Read against the oldest base kept (before the x)
    # or the next (after the take-back), w1's x read as A's and came back.
    assert html =~ "Someone else rewrote"
    assert words(stored(c)["meta"]["rt"]) == ["one two" | with_x_from(@blocks, 2, 9)]
  end

  # An " x" on w`from`..w`to`.
  defp with_x_from(blocks, from, to) do
    blocks
    |> Enum.with_index(1)
    |> Enum.map(fn {b, i} -> if i >= from and i <= to, do: b <> " x", else: b end)
  end
end
