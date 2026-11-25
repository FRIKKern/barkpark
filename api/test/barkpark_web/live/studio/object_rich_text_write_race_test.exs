defmodule BarkparkWeb.Studio.ObjectRichTextWriteRaceTest do
  # task-00c56c6a88ed0b8f: two tabs post one rich text at once. B's save
  # lands after A's post is read and before A's write, so A's socket has not
  # heard of it: A's post reads as current. In real Chrome (scratchpad
  # rig, case `sameword`) the second write was laid over the first with no
  # banner, on the desk and in Studio.
  #
  # The order is forced (`b_saves_inside/4`): B's save runs inside A's post.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  setup %{conn: conn}, do: setup_doc(conn)

  for surface <- [:desk, :studio] do
    test "#{surface}: both type in one word, B's save lands under A's post: held, B's words stored",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        b_saves_inside(a, b, "<p>one twB</p>", fn -> post_rt(a, "<p>one twoA</p>", 0) end)

      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      assert html =~ "Someone else rewrote"
    end

    test "#{surface}: each types in a word of their own, B's save lands under A's post: both kept",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        b_saves_inside(a, b, "<p>one TWO</p>", fn -> post_rt(a, "<p>ONE two</p>", 0) end)

      assert words(stored(c)["meta"]["rt"]) == ["ONE TWO"]
      refute html =~ "Someone else rewrote"
    end
  end
end
