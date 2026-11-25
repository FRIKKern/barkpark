defmodule BarkparkWeb.Studio.ObjectRichTextHoldTest do
  @moduledoc """
  task-47be2cdf59d0acd5 (#28349 r4): a post typed over another editor's
  change of the same block of a rich text in an object is held with the
  conflict banner, theirs in it. A's view is sent; only typing on what A's
  editor showed saves A's block over theirs. Reload, Save and an IME commit
  take the same path.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @event "bp:rt-remote"

  setup %{conn: conn}, do: setup_doc(conn)

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: A and B rewrote the same block: theirs stays stored and is in the banner; only typing on what A was shown saves A's",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      view = held_by_clash(a, b, c)

      assert words(stored(c)["meta"]["rt"]) == ["one TWO", "B para"]
      assert words(form(a)["meta"]["rt"]) == ["one twoA", "B para"]

      assert render(a) =~
               ~r|<blockquote class="bp-doc-conflict-theirs"[^>]*>one TWO</blockquote>|

      # A typed on before its editor showed the view: held again.
      html = post_rt(a, "<p>one twoAA</p><p>B para</p>", view - 1)
      assert words(stored(c)["meta"]["rt"]) == ["one TWO", "B para"]
      assert html =~ "Someone else rewrote"
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: view2}}}, 2_000)

      # Typing on what A was shown saves A's block; B's paragraph stays.
      post_rt(a, "<p>one twoAAA</p><p>B para</p>", view2)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one twoAAA", "B para"] end)
    end

    # Held, then B saves again: a paragraph B2 adds reaches A's held view,
    # and typing on it keeps it.
    test "#{surface}: while A is held, another save of the same rich text is merged into A's view",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      _view = held_by_clash(a, b, c)

      send_post(b, "doc[meta].rt", %{
        "doc[meta].label" => "l0",
        "doc[meta].rt" => "<p>one TWO</p><p>B para</p><p>B2 para</p>"
      })

      assert eventually(fn -> length(stored(c)["meta"]["rt"]) == 3 end)

      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: v, html: html}}}, 2_000)
      assert html =~ "one twoA" and html =~ "B2 para"
      assert words(form(a)["meta"]["rt"]) == ["one twoA", "B para", "B2 para"]

      post_rt(a, "<p>one twoAX</p><p>B para</p><p>B2 para</p>", v)

      assert eventually(fn ->
               words(stored(c)["meta"]["rt"]) == ["one twoAX", "B para", "B2 para"]
             end)
    end
  end

  # #28349 r3 review, K6: the hold drew the banner above an id-less
  # fieldset; the patch took the fieldset out and put it back, which blurred
  # the editor and ended A's IME composition.
  # The id alone was not enough in Chrome: morphdom met the new banner where
  # the fieldset was and moved the fieldset to put it in. The banner has an
  # always-drawn slot, so the children around the fields never change.
  test "desk: a hold draws the banner inside its slot, the fields' fieldset keeps its place",
       c do
    a = open(c)
    b = open(c)
    before = render(a)
    assert before =~ ~s(<div id="doc-conflict-slot")
    assert before =~ ~s(<fieldset id="dk-readonly-fields")
    _ = held_by_clash(a, b, c)
    html = render(a)

    assert html =~
             ~r|<div id="doc-conflict-slot"[^>]*>\s*<div class="bp-violations bp-doc-conflict"|

    assert html =~ ~s(<fieldset id="dk-readonly-fields")
  end

  # #28349 r2 review, SV2: Reload took theirs into the form but the editor
  # kept A's held words, and A's next word wrote them over B's, with no
  # banner.
  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: Reload sends the stored text to show at once; a post from an editor that never showed it is held",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      view = held_by_clash(a, b, c)

      a |> element("[phx-click=reload-remote-doc]") |> render_click()

      assert_push_event(
        a,
        @event,
        %{values: %{"doc[meta].rt" => %{seq: shown, html: html, reload: true}}},
        2_000
      )

      assert shown > view and html =~ "one TWO"
      assert words(form(a)["meta"]["rt"]) == ["one TWO", "B para"]
      refute render(a) =~ "bp-doc-conflict-theirs"

      # An editor that still shows A's held words: held again, B's stays.
      html = post_rt(a, "<p>one twoAZ</p><p>B para</p>", shown - 1)
      assert words(stored(c)["meta"]["rt"]) == ["one TWO", "B para"]
      assert html =~ "Someone else rewrote"

      # The editor showed it: A's word lands on B's text.
      a |> element("[phx-click=reload-remote-doc]") |> render_click()

      assert_push_event(
        a,
        @event,
        %{values: %{"doc[meta].rt" => %{seq: again, reload: true}}},
        2_000
      )

      post_rt(a, "<p>one TWO Z</p><p>B para</p>", again)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one TWO Z", "B para"] end)
    end

    # #28349 r2 review, V1: an explicit Save skipped the check and wrote A's
    # stale text over B's.
    test "#{surface}: a Save of a stale rich text is held as an autosave is", c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)

      b_saves_rt(b, c, "<p>one TWO</p>", ["one TWO"])
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

      html =
        a
        |> element("#editor-form")
        |> render_submit(%{
          "doc" => %{"title" => "T0"},
          "doc[meta].label" => "l0 A",
          "doc[meta].rt" => "<p>one twoA</p>",
          "_bp_rt_seen" => ["doc[meta].rt|#{seq - 1}"]
        })

      assert eventually(fn -> stored(c)["meta"]["label"] == "l0 A" end)
      assert words(stored(c)["meta"]["rt"]) == ["one TWO"]
      assert words(form(a)["meta"]["rt"]) == ["one twoA"]
      assert html =~ "Someone else rewrote"
    end
  end

  # #28349 r3, S6b: A's composition was under way when the hold came, and
  # its commit counted as typing on. The page reports the number before the
  # view it has not shown yet, so the commit is read against theirs again
  # and held. Typing on the view it showed saves A's.
  test "the commit of a composition begun before the hold is held again; input after it types on",
       c do
    a = open(c)
    b = open(c)
    view = held_by_clash(a, b, c)

    html = post_rt(a, "<p>one twoAか漢</p><p>B para</p>", view - 1)

    assert words(stored(c)["meta"]["rt"]) == ["one TWO", "B para"]
    assert words(form(a)["meta"]["rt"]) == ["one twoAか漢", "B para"]
    assert html =~ "Someone else rewrote"
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: view2}}}, 2_000)

    post_rt(a, "<p>one twoAか漢 Q</p><p>B para</p>", view2)
    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one twoAか漢 Q", "B para"] end)
  end

  # #28349 r4 review, blocker 1 (J): an IME commit re-posts the held text
  # with the number before the view; it read as "A changed nothing" and
  # dropped the hold, and A's next key wrote A's block over B's unseen.
  # Review H: a post of the view unchanged, with its number, saved A's block
  # over theirs. A hold ends only on a post that carries the view's number
  # and differs from the view.
  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: H: the view posted unchanged with its number saves nothing over theirs; the banner stays",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      view = held_by_clash(a, b, c)
      theirs = stored(c)["meta"]["rt"]

      html = post_rt(a, "<p>one twoA</p><p>B para</p>", view)
      assert html =~ "Someone else rewrote"
      assert stored(c)["meta"]["rt"] == theirs
      assert words(form(a)["meta"]["rt"]) == ["one twoA", "B para"]
    end

    test "#{surface}: J: the held text posted again stays held; the view posted unchanged saves nothing; typing on saves A's",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      view = held_by_clash(a, b, c)
      theirs = stored(c)["meta"]["rt"]

      html = post_rt(a, "<p>one twoA</p><p>B para</p>", view - 1)
      assert html =~ "Someone else rewrote"
      assert stored(c)["meta"]["rt"] == theirs
      assert words(form(a)["meta"]["rt"]) == ["one twoA", "B para"]
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: view2}}}, 2_000)
      assert view2 > view

      html = post_rt(a, "<p>one twoA</p><p>B para</p>", view2)
      assert html =~ "Someone else rewrote"
      assert stored(c)["meta"]["rt"] == theirs
      assert words(form(a)["meta"]["rt"]) == ["one twoA", "B para"]

      html = post_rt(a, "<p>one twoAZ</p><p>B para</p>", view2)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one twoAZ", "B para"] end)
      refute html =~ "bp-doc-conflict-theirs"
    end

    # Review 06 and 33, end to end: a split of the block B edited, and both
    # deleting a block while B edits the next one, wrote words nobody typed
    # (06) or lost B's block (33). Neither can be lined up block by block:
    # the store keeps B's value exactly, A keeps its own in the editor.
    test "#{surface}: 06 and 33: a post that cannot be lined up leaves B's value stored as it is",
         c do
      c = %{c | surface: @surface}

      for {b_html, a_html, banner} <- [
            {"<p>P</p><p>Q one two B</p><p>R</p>", "<p>P</p><p>Q one</p><p> two</p><p>R</p>",
             "Q one two B"},
            {"<p>P</p><p>R B</p>", "<p>P</p><p>R</p>", "R B"}
          ] do
        a = open(c)
        b = open(c)
        b_saves_rt(b, c, "<p>P</p><p>Q one two</p><p>R</p>", ["P", "Q one two", "R"])
        assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seen}}}, 2_000)
        send_post(b, "doc[meta].rt", %{"doc[meta].label" => "l0", "doc[meta].rt" => b_html})
        assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: _}}}, 2_000)
        theirs = stored(c)["meta"]["rt"]

        html = post_rt(a, a_html, seen)
        assert html =~ "Someone else rewrote"
        assert html =~ ~r|<blockquote class="bp-doc-conflict-theirs"[^>]*>#{banner}</blockquote>|
        assert stored(c)["meta"]["rt"] == theirs
        assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{html: shown}}}, 2_000)
        assert shown == Barkpark.Content.PortableText.to_html(form(a)["meta"]["rt"])
      end
    end
  end

  # task-13351734f4f8d2f6 (plan /papers/pt-merge-inside-one-block, task 3):
  # with the merge inside one block, B's edit of word 1 and A's of word 3
  # of the same block are both stored, and A typing on before its editor
  # shows the merge (K8: the page reports the merge's number - 1) saves only
  # its new letters.
  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: B edits word 1, A word 3 of the same block, A types on before the merge is shown: both stored once, no banner",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)

      b_saves_rt(b, c, "<p>one two three</p>", ["one two three"])
      page = got(page(), next_push(a), true)

      b_saves_rt(b, c, "<p>ONE two three</p>", ["ONE two three"])
      page = got(page, next_push(a), false)

      html = post_rt(a, "<p>one two THREE</p>", seen(page))
      assert words(stored(c)["meta"]["rt"]) == ["ONE two THREE"]
      refute html =~ "Someone else rewrote"

      merge = next_push(a)
      assert merge[:own] and merge.html =~ "ONE two THREE"
      page = got(page, merge, false)
      assert seen(page) == merge.seq - 1

      html = post_rt(a, "<p>one two THREEx</p>", seen(page))
      assert words(stored(c)["meta"]["rt"]) == ["ONE two THREEx"]
      refute html =~ "Someone else rewrote"
      page = got(page, next_push(a), false)

      # Shown: A types on the merged text, every word once.
      html = post_rt(a, "<p>ONE two THREExy</p>", seen(drew(page)))
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["ONE two THREExy"] end)
      refute html =~ "Someone else rewrote"
    end
  end
end
