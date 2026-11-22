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

      assert words(stored(c)["meta"]["rt"]) == ["B one two", "B para"]
      assert words(form(a)["meta"]["rt"]) == ["one two A", "B para"]

      assert render(a) =~
               ~r|<blockquote class="bp-doc-conflict-theirs"[^>]*>B one two</blockquote>|

      # A typed on before its editor showed the view: held again.
      html = post_rt(a, "<p>one two AA</p>", view - 1)
      assert words(stored(c)["meta"]["rt"]) == ["B one two", "B para"]
      assert html =~ "Someone else rewrote"
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: view2}}}, 2_000)

      # Typing on what A was shown saves A's block; B's paragraph stays.
      post_rt(a, "<p>one two AAA</p><p>B para</p>", view2)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one two AAA", "B para"] end)
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
        "doc[meta].rt" => "<p>B one two</p><p>B para</p><p>B2 para</p>"
      })

      assert eventually(fn -> length(stored(c)["meta"]["rt"]) == 3 end)

      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: v, html: html}}}, 2_000)
      assert html =~ "one two A" and html =~ "B2 para"
      assert words(form(a)["meta"]["rt"]) == ["one two A", "B para", "B2 para"]

      post_rt(a, "<p>one two AX</p><p>B para</p><p>B2 para</p>", v)

      assert eventually(fn ->
               words(stored(c)["meta"]["rt"]) == ["one two AX", "B para", "B2 para"]
             end)
    end
  end

  # #28349 r3 review, K6: the hold drew the banner above an id-less
  # fieldset; the patch took the fieldset out and put it back, which blurred
  # the editor and ended A's IME composition.
  test "desk: the fields' fieldset keeps one id through a hold, so the patch keeps it in place",
       c do
    a = open(c)
    b = open(c)
    assert render(a) =~ ~s(<fieldset id="dk-readonly-fields")
    _ = held_by_clash(a, b, c)
    assert render(a) =~ "bp-doc-conflict"
    assert render(a) =~ ~s(<fieldset id="dk-readonly-fields")
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

      assert shown > view and html =~ "B one two"
      assert words(form(a)["meta"]["rt"]) == ["B one two", "B para"]
      refute render(a) =~ "bp-doc-conflict-theirs"

      # An editor that still shows A's held words: held again, B's stays.
      html = post_rt(a, "<p>one two AZ</p><p>B para</p>", shown - 1)
      assert words(stored(c)["meta"]["rt"]) == ["B one two", "B para"]
      assert html =~ "Someone else rewrote"

      # The editor showed it: A's word lands on B's text.
      a |> element("[phx-click=reload-remote-doc]") |> render_click()

      assert_push_event(
        a,
        @event,
        %{values: %{"doc[meta].rt" => %{seq: again, reload: true}}},
        2_000
      )

      post_rt(a, "<p>B one two Z</p><p>B para</p>", again)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["B one two Z", "B para"] end)
    end

    # #28349 r2 review, V1: an explicit Save skipped the check and wrote A's
    # stale text over B's.
    test "#{surface}: a Save of a stale rich text is held as an autosave is", c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)

      b_saves_rt(b, c, "<p>B one two</p>", ["B one two"])
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

      html =
        a
        |> element("#editor-form")
        |> render_submit(%{
          "doc" => %{"title" => "T0"},
          "doc[meta].label" => "l0 A",
          "doc[meta].rt" => "<p>one two A</p>",
          "_bp_rt_seen" => ["doc[meta].rt|#{seq - 1}"]
        })

      assert eventually(fn -> stored(c)["meta"]["label"] == "l0 A" end)
      assert words(stored(c)["meta"]["rt"]) == ["B one two"]
      assert words(form(a)["meta"]["rt"]) == ["one two A"]
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

    html = post_rt(a, "<p>one two Aか漢</p>", view - 1)

    assert words(stored(c)["meta"]["rt"]) == ["B one two", "B para"]
    assert words(form(a)["meta"]["rt"]) == ["one two Aか漢", "B para"]
    assert html =~ "Someone else rewrote"
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: view2}}}, 2_000)

    post_rt(a, "<p>one two Aか漢 Q</p><p>B para</p>", view2)
    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one two Aか漢 Q", "B para"] end)
  end
end
