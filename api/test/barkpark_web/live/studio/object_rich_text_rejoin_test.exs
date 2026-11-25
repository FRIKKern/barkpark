defmodule BarkparkWeb.Studio.ObjectRichTextRejoinTest do
  @moduledoc """
  task-eeda66fac5af065f (#28755 review, should fix 2): a page that rejoins
  a new socket keeps its editors and the numbers of the old socket, whose
  log is gone. A post on such a number was read as current and saved over
  B's change. A connected mount now sends each rich text its stored value
  (`RichTextRemote.born/1`); a post older than it is held unless it is the
  stored value.
  """
  use BarkparkWeb.ConnCase, async: false

  import BarkparkWeb.ObjectRichText

  setup %{conn: conn}, do: setup_doc(conn)

  # The page's open view goes; the same page joins a new socket.
  defp rejoin(c), do: open(c)

  defp waiting_b(c) do
    a = open(c)
    b = open(c)
    b_saves_rt(b, c, "<p>one two</p><p>p1</p>", ["one two", "p1"])
    page = got(page(), next_push(a), true)
    b_saves_rt(b, c, "<p>one two</p><p>p1 b</p>", ["one two", "p1 b"])
    {b, got(page, next_push(a), false)}
  end

  # The desk makes a new editor on rejoin; Studio keeps it (#28779 review).
  # The server reads both alike.
  for surface <- [:desk, :studio] do
    test "#{surface}: B's change waits, the page rejoins, A posts on the old number: held, B's change stored",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {_b, page} = waiting_b(c)
      a2 = rejoin(c)

      html = post_rt(a2, "<p>one twoA</p><p>p1</p>", seen(page))

      # Read as current, A's text was saved over B's "b" with no banner.
      assert html =~ "Someone else rewrote"
      assert words(stored(c)["meta"]["rt"]) == ["one two", "p1 b"]
    end

    test "#{surface}: the page rejoins and posts the stored value back on the old number: nothing changes, no banner",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {_b, page} = waiting_b(c)
      a2 = rejoin(c)

      html = post_rt(a2, "<p>one two</p><p>p1 b</p>", seen(page))

      refute html =~ "Someone else rewrote"
      assert words(stored(c)["meta"]["rt"]) == ["one two", "p1 b"]
    end

    test "#{surface}: a page that never had a value reports 0: its post is read as typed on this mount",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      html = post_rt(a, "<p>one twoA</p>", 0)

      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one twoA"] end)
      refute html =~ "Someone else rewrote"
    end

    test "#{surface}: the page rejoins, draws the stored value at idle, and types on it: saved as typed",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {_b, page} = waiting_b(c)
      a2 = rejoin(c)
      v = %{seq: born_seq(a2)}
      page = got(page, Map.put(v, :born, true), true)

      html = post_rt(a2, "<p>one two</p><p>p1 bA</p>", seen(page))

      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one two", "p1 bA"] end)
      refute html =~ "Someone else rewrote"
    end
  end

  defp born_seq(view) do
    {seq, _value} = :sys.get_state(view.pid).socket.assigns.editor_rt_born["doc[meta].rt"]
    seq
  end
end
