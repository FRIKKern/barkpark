defmodule BarkparkWeb.Studio.ObjectRichTextRemoteTest do
  @moduledoc """
  task-47be2cdf59d0acd5: rich text inside an object or a row is drawn in a
  `phx-update="ignore"` wrapper. B's save of it reached A's form, but A's
  editor kept the old text, and A's next post wrote it back over B's. A
  remount would throw away A's unposted typing (#28349 review), so the
  server sends theirs to the open editor in place (`bp:rt-remote`), and a
  post typed over theirs is held with the conflict banner, never written
  over it (`Handlers.RichTextRemote`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @event "bp:rt-remote"

  setup %{conn: conn}, do: setup_doc(conn)

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: B edits meta.rt: A's open editor is sent theirs, never remounted", c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)
      before = wraps(a)

      b_saves_rt(b, c, "<p>one two</p><p>B para</p>", ["one two", "B para"])

      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq, html: html}}}, 2_000)
      assert is_integer(seq) and html =~ "B para"
      assert wraps(a) == before
    end

    # #28349 r3 review, K5/S5p/K8: B added a paragraph while A typed in
    # another block. A's post was held, and A's next one wrote over B's
    # paragraph, which A's editor never showed.
    test "#{surface}: B adds a paragraph while A types in another block: both are saved, no banner",
         c do
      c = %{c | surface: @surface}
      a = open(c)
      b = open(c)

      b_saves_rt(b, c, "<p>one two</p><p>B para</p>", ["one two", "B para"])
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

      html = post_rt(a, "<p>one twoHel</p>", seq - 1)

      assert words(stored(c)["meta"]["rt"]) == ["one twoHel", "B para"]
      refute html =~ "Someone else rewrote"
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: m, html: merged}}}, 2_000)
      assert m > seq and merged =~ "one twoHel" and merged =~ "B para"

      # K8: A types on before its editor has shown the merge.
      post_rt(a, "<p>one twoHello</p>", m - 1)
      assert words(stored(c)["meta"]["rt"]) == ["one twoHello", "B para"]
      assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: m2}}}, 2_000)

      # Shown: A's text is saved as typed.
      post_rt(a, "<p>one twoHello!</p><p>B para</p>", m2)
      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one twoHello!", "B para"] end)
      refute render(a) =~ "Someone else rewrote"
    end
  end

  # task-fbe81bb824c6df0e, task-2833650e2e72d380: B saves twice while A
  # types. A's page drew neither B's paragraph nor the merge of A's first
  # post. It used to report the newest waiting value's number - 1, so A's
  # next post was read against B's second save, which has P1 that A's post
  # does not: held with a false banner (#28748 pinned that). It now reports
  # one less than the merge of its own post (`own`), and the post merges.
  test "B saves twice while A types: A's next post merges, B's paragraphs stay, no banner", c do
    a = open(c)
    b = open(c)

    b_saves_rt(b, c, "<p>one two</p><p>P1</p>", ["one two", "P1"])
    page = got(page(), next_push(a), false)

    post_rt(a, "<p>one twoA</p>", seen(page))
    assert words(stored(c)["meta"]["rt"]) == ["one twoA", "P1"]
    page = got(page, next_push(a), false)

    b_saves_rt(b, c, "<p>one twoA</p><p>P1</p><p>P2</p>", ["one twoA", "P1", "P2"])
    page = got(page, next_push(a), false)

    html = post_rt(a, "<p>one twoAB</p>", seen(page))

    assert words(stored(c)["meta"]["rt"]) == ["one twoAB", "P1", "P2"]
    refute html =~ "Someone else rewrote"
  end

  # task-2833650e2e72d380: A's page shows p1; B adds a word to p1, then adds
  # p2, both waiting while A types. The page reports one less than the
  # first, B's word: it is never read as A's delete of it.
  test "B's word, then B's paragraph, both waiting on A's page: B's word stays", c do
    {p1, p2} = {"alpha beta gamma delta", "zeta eta theta iota"}
    a = open(c)
    b = open(c)

    b_saves_rt(b, c, "<p>one two</p><p>#{p1}</p>", ["one two", p1])
    page = got(page(), next_push(a), true)
    b_saves_rt(b, c, "<p>one two</p><p>#{p1} epsilon</p>", ["one two", p1 <> " epsilon"])
    page = got(page, next_push(a), false)

    b_saves_rt(b, c, "<p>one two</p><p>#{p1} epsilon</p><p>#{p2}</p>", [
      "one two",
      p1 <> " epsilon",
      p2
    ])

    page = got(page, next_push(a), false)

    html = post_rt(a, "<p>one twoA</p><p>#{p1}</p>", seen(page))

    assert words(stored(c)["meta"]["rt"]) |> Enum.member?(p1 <> " epsilon")

    assert html =~ "Someone else rewrote" or
             words(stored(c)["meta"]["rt"]) == ["one twoA", p1 <> " epsilon", p2]
  end

  test "B saves the sibling meta.rt2: only rt2 is sent", c do
    a = open(c)
    b = open(c)

    send_post(b, "doc[meta].rt2", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt2" => "<p>second B</p>"
    })

    assert eventually(fn -> words(stored(c)["meta"]["rt2"]) == ["second B"] end)

    assert_push_event(a, @event, %{values: values}, 2_000)
    assert Map.keys(values) == ["doc[meta].rt2"]
  end

  test "B edits the rich text of a row in the object: A's editor is sent it", c do
    a = open(c)
    b = open(c)
    before = wraps(a)
    assert Map.has_key?(before, "doc[meta].rows[0].rt")

    send_post(b, "doc[meta].rows[0].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rows[0]._type" => "row",
      "doc[meta].rows[0]._key" => "r1",
      "doc[meta].rows[0].rt" => "<p>rowtext B</p>"
    })

    assert eventually(fn -> words(hd(stored(c)["meta"]["rows"])["rt"]) == ["rowtext B"] end)

    assert_push_event(
      a,
      @event,
      %{values: %{"doc[meta].rows[0].rt" => %{html: html}}},
      2_000
    )

    assert html =~ "rowtext B"
    assert wraps(a) == before
  end

  test "after A's own post of a linked text, B's saves of a string and the top-level body send A nothing",
       c do
    c = %{c | id: c.id <> "-link"}
    a = open(c)
    b = open(c)

    # A's own post comes back with new keys: no change of what it draws.
    send_post(a, "doc[meta].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt" => ~s(<p>one A <a href="https://x.example" data-pt-def="m1">two</a></p>)
    })

    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one A two"] end)

    # B's page was sent A's text but, with no browser here, its hidden input
    # still holds the old one: it reports the number it showed, as
    # bp-rt-remote.js does, and its old text is not written over A's.
    seen = %{"_bp_rt_seen" => ["doc[meta].rt|0"]}
    send_post(b, "doc[meta].label", Map.put(seen, "doc[meta].label", "l0 B"))
    assert eventually(fn -> stored(c)["meta"]["label"] == "l0 B" end)

    b
    |> element("#editor-form")
    |> render_change(
      Map.merge(seen, %{
        "_target" => ["doc", "body"],
        "doc" => %{"title" => "T0", "body" => "<p>body B</p>"}
      })
    )

    assert eventually(fn -> words(stored(c)["body"]) == ["body B"] end)
    assert eventually(fn -> form(a)["meta"]["label"] == "l0 B" end)
    assert words(stored(c)["meta"]["rt"]) == ["one A two"]
    refute_push_event(a, @event, %{values: _}, 300)
  end

  test "A's post of another field carries the old text it never touched: theirs stands", c do
    a = open(c)
    b = open(c)

    b_saves_rt(b, c, "<p>one two B</p>", ["one two B"])
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{seq: seq}}}, 2_000)

    html =
      send_post(a, "doc[meta].label", %{
        "doc[meta].label" => "l0 A",
        "doc[meta].rt" => "<p>one two</p>",
        "_bp_rt_seen" => ["doc[meta].rt|#{seq - 1}"]
      })

    assert eventually(fn -> stored(c)["meta"]["label"] == "l0 A" end)
    assert words(stored(c)["meta"]["rt"]) == ["one two B"]
    refute html =~ "Someone else rewrote"
  end

  test "a post with no _bp_rt_seen (a page from before) is written as before", c do
    a = open(c)
    b = open(c)

    b_saves_rt(b, c, "<p>one two B</p>", ["one two B"])
    assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["one two B"] end)

    send_post(a, "doc[meta].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt" => "<p>one two A</p>"
    })

    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one two A"] end)
  end

  # #28349 r2 review, S9: past 20k the page was told only that it changed,
  # so an idle A never showed it and A's next post was held, then saved over
  # it.
  test "theirs past 20k is sent whole, in an event of its own", c do
    a = open(c)
    b = open(c)
    long = String.duplicate("word ", 5_000)

    b_saves_rt(b, c, "<p>#{long}</p>", [String.trim_trailing(long)])

    assert_push_event(
      a,
      @event,
      %{values: %{"doc[meta].rt" => %{seq: seq, html: html}} = told},
      2_000
    )

    assert map_size(told) == 1
    assert is_integer(seq) and byte_size(html) > 20_000 and html =~ "word word"
  end

  test "theirs is sent as the first paint draws it: markup typed as text stays text", c do
    a = open(c)
    b = open(c)

    send_post(b, "doc[meta].rt", %{
      "doc[meta].label" => "l0",
      "doc[meta].rt" =>
        ~s|<p>&lt;img src=x onerror=alert(1)&gt;&lt;script&gt;x()&lt;/script&gt; <a href="javascript:alert(1)">go</a></p>|
    })

    assert eventually(fn -> hd(words(stored(c)["meta"]["rt"])) =~ "<img src=x" end)
    assert_push_event(a, @event, %{values: %{"doc[meta].rt" => %{html: html}}}, 2_000)

    assert html == Barkpark.Content.PortableText.to_html(stored(c)["meta"]["rt"])
    refute html =~ "<img"
    refute html =~ "<script"
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
  end
end
