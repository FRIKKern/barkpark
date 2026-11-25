defmodule BarkparkWeb.Studio.ObjectRichTextRowRaceTest do
  @moduledoc """
  task-2dce62676ad14c3c: a rich text in an array row, two tabs posting it at
  once. B's save lands after A's post is read and before A's write
  (`b_saves_inside/4`), so A's socket reads A's post as current.
  `ObjectRebase` did not descend an array, so the row was written as A
  posted it: B's word was gone with no banner, and `UnderLock.acts/4`
  reported it merged.

  A row's rich text is now read under the lock as an object's is: the store
  still holds what A's page saw, and A's post is written; it moved, and A's
  post is merged onto it; a clash keeps the store and holds A.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  @name "doc[meta].rows[0].rt"
  @rb "Someone else rewrote"

  setup %{conn: conn}, do: setup_doc(conn)

  defp row_post(view, html, seen) do
    fields = %{
      "doc[meta].label" => "l0",
      "doc[meta].rows[0]._type" => "row",
      "doc[meta].rows[0]._key" => "r1",
      @name => html
    }

    fields = if seen, do: Map.put(fields, "_bp_rt_seen", ["#{@name}|#{seen}"]), else: fields
    send_post(view, @name, fields)
  end

  defp b_row(b, html), do: fn -> row_post(b, html, nil) end

  defp row_words(c), do: words(hd(stored(c)["meta"]["rows"])["rt"])

  for surface <- [:desk, :studio] do
    test "#{surface}: both type in one word, B's save lands under A's post: held, B's words stored",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html = inside(a, b_row(b, "<p>rowtexB</p>"), fn -> row_post(a, "<p>rowtextA</p>", 0) end)

      assert row_words(c) == ["rowtexB"]
      assert html =~ @rb

      assert_push_event(a, "bp:rt-remote", %{values: %{@name => %{html: view}}}, 2_000)
      assert view =~ "rowtextA"
    end

    test "#{surface}: each types in a word of their own, B's save lands under A's post: both kept",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      row_post(b, "<p>one rowtext two</p>", nil)
      assert eventually(fn -> row_words(c) == ["one rowtext two"] end)

      assert_push_event(a, "bp:rt-remote", %{values: %{@name => %{seq: seq}}}, 2_000)

      html =
        inside(a, b_row(b, "<p>one rowtext TWO</p>"), fn ->
          row_post(a, "<p>ONE rowtext two</p>", seq)
        end)

      assert row_words(c) == ["ONE rowtext TWO"]
      refute html =~ @rb
    end

    test "#{surface}: no other save: A's row post is written as posted, no banner", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      html = row_post(a, "<p>rowtext A</p>", 0)
      assert eventually(fn -> row_words(c) == ["rowtext A"] end)
      refute html =~ @rb
    end
  end
end
