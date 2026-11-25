defmodule BarkparkWeb.Studio.ObjectRichTextWriteRaceReviewTest do
  # The #28792 review's probes (task-00c56c6a88ed0b8f), B's save inside A's
  # post (`b_saves_inside/4`):
  #   B1: `split/3` merged a change A's page was told of; the act and its
  #       log name A's own text, not the merge, or A's next post took the
  #       change back out.
  #   B2: a post that left the rich text as A believed it stored has nothing
  #       of A's to hold: no banner.
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

  for surface <- [:desk, :studio] do
    test "#{surface}: split merges a waiting B1, B2 lands under the lock, A types on before drawing",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      b_saves_rt(b, c, "<p>one two three four five</p>", ["one two three four five"])
      page = Enum.reduce(pushes(a), page(), &got(&2, &1, true))
      _ = pushes(b)

      # B1 waits on A's page (A typing).
      b_saves_rt(b, c, "<p>one two THREE four five</p>", ["one two THREE four five"])
      page = Enum.reduce(pushes(a), page, &got(&2, &1, false))

      b_saves_inside(a, b, "<p>one two THREE four FIVE</p>", fn ->
        post_rt(a, "<p>ONE two three four five</p>", seen(page))
      end)

      assert words(stored(c)["meta"]["rt"]) == ["ONE two THREE four FIVE"]
      page = Enum.reduce(pushes(a), page, &got(&2, &1, false))

      # A typed on its own text, B1 and B2 not drawn yet.
      html = post_rt(a, "<p>ONE TWO three four five</p>", seen(page))

      refute html =~ @banner
      assert words(stored(c)["meta"]["rt"]) == ["ONE TWO THREE four FIVE"]
    end

    test "#{surface}: A edits only the label, B's rt save lands inside A's post", c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        b_saves_inside(a, b, "<p>one twB</p>", fn ->
          send_post(a, "doc[meta].label", %{
            "doc[meta].label" => "l1",
            "doc[meta].rt" => "<p>one two</p>",
            "_bp_rt_seen" => ["doc[meta].rt|0"]
          })
        end)

      st = stored(c)["meta"]
      assert words(st["rt"]) == ["one twB"]
      assert st["label"] == "l1"
      refute html =~ @banner
    end

    test "#{surface}: A edits only the title, B's rt save lands inside A's post", c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        b_saves_inside(a, b, "<p>one twB</p>", fn ->
          a
          |> element("#editor-form")
          |> render_change(%{
            "_target" => ["doc", "title"],
            "doc" => %{"title" => "T1", "meta" => %{"label" => "l0", "rt" => "<p>one two</p>"}},
            "_bp_rt_seen" => ["doc[meta].rt|0"]
          })
        end)

      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      refute html =~ @banner
    end

    test "#{surface}: A edits rt2, B's rt save lands inside A's post", c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        b_saves_inside(a, b, "<p>one twB</p>", fn ->
          send_post(a, "doc[meta].rt2", %{
            "doc[meta].label" => "l0",
            "doc[meta].rt" => "<p>one two</p>",
            "doc[meta].rt2" => "<p>second A</p>",
            "_bp_rt_seen" => ["doc[meta].rt|0", "doc[meta].rt2|0"]
          })
        end)

      st = stored(c)["meta"]
      assert words(st["rt"]) == ["one twB"]
      assert words(st["rt2"]) == ["second A"]
      refute html =~ @banner
    end

    test "#{surface}: a single editor types in one word, many posts", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)

      html =
        Enum.reduce(~w(A AB ABC ABCD), nil, fn s, _ -> post_rt(a, "<p>one two#{s}</p>", 0) end)

      html =
        send_post(a, "doc[meta].label", %{
          "doc[meta].label" => "l9",
          "doc[meta].rt" => "<p>one twoABCD</p>",
          "_bp_rt_seen" => ["doc[meta].rt|0"]
        }) || html

      html = post_rt(a, "<p>one twoABCDE</p>", 0) || html
      st = stored(c)["meta"]
      assert words(st["rt"]) == ["one twoABCDE"] and st["label"] == "l9"
      refute html =~ @banner
    end
  end
end
