defmodule BarkparkWeb.Studio.ObjectRichTextWriteRaceTest do
  # task-00c56c6a88ed0b8f: two tabs post one rich text at once. B's save
  # lands after A's post is read and before A's write, so A's socket has not
  # heard of it: A's post reads as current. In real Chrome (scratchpad
  # rig, case `sameword`) the second write was laid over the first with no
  # banner, on the desk and in Studio.
  #
  # The order is forced (`race/4`): B's save runs inside A's post.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  setup %{conn: conn}, do: setup_doc(conn)

  # B's save runs inside A's post: on A's first query after the post
  # starts, before A's write. A's process cannot read B's broadcast until
  # the post is done, so A's socket reads the post as current, as both
  # Chrome tabs did.
  defp race(a, b, b_html, a_post) do
    {a_pid, once} = {a.pid, :atomics.new(1, [])}
    id = "rt-write-race-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _event, _measure, _meta, _ ->
        if self() == a_pid and :atomics.compare_exchange(once, 1, 0, 1) == :ok,
          do: send_post(b, "doc[meta].rt", %{"doc[meta].label" => "l0", "doc[meta].rt" => b_html})
      end,
      nil
    )

    try do
      a_post.()
    after
      :telemetry.detach(id)
      assert :atomics.get(once, 1) == 1, "B's save never ran inside A's post"
    end
  end

  for surface <- [:desk, :studio] do
    test "#{surface}: both type in one word, B's save lands under A's post: held, B's words stored",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        race(a, b, "<p>one twB</p>", fn -> post_rt(a, "<p>one twoA</p>", 0) end)

      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      assert html =~ "Someone else rewrote"
    end

    test "#{surface}: each types in a word of their own, B's save lands under A's post: both kept",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        race(a, b, "<p>one TWO</p>", fn -> post_rt(a, "<p>ONE two</p>", 0) end)

      assert words(stored(c)["meta"]["rt"]) == ["ONE TWO"]
      refute html =~ "Someone else rewrote"
    end
  end
end
