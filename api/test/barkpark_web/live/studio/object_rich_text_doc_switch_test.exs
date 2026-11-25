defmodule BarkparkWeb.Studio.ObjectRichTextDocSwitchTest do
  @moduledoc """
  task-29686209fb9fc5dc (#28755 review, should fix 3): `RichTextRemote`'s
  log is keyed by input name, not by document. A change B saved on the
  first document, still waiting on A's page when A opens a second document
  of the same type, must not be read against A's post on the second.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  setup %{conn: conn} do
    c = setup_doc(conn)
    id2 = c.id <> "-two"

    {:ok, _} =
      Content.create_document(
        c.type,
        %{
          "doc_id" => id2,
          "title" => "T2",
          "content" => %{"meta" => %{"label" => "l0", "rt" => [block("d1", "doc two text")]}}
        },
        "production"
      )

    Map.put(c, :id2, id2)
  end

  test "B's change waits on A's page, A opens another document and types: it saves as typed", c do
    a = open(c)
    b = open(c)
    b_saves_rt(b, c, "<p>one two B</p>", ["one two B"])
    page = got(page(), next_push(a), false)

    render_patch(a, "#{c.root}/_desk/#{c.type};#{c.id2}")
    assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["doc two text"] end)
    assert_push_event(a, "bp:rt-remote", %{forget: true}, 2_000)

    # The page dropped what waited (bp-rt-remote.js); the number it reports
    # is still the one from the first document.
    html = post_rt(a, "<p>doc two text A</p>", seen(page))

    # Read against the first document's log, B's text of it was saved into
    # this one, with the banner.
    two = %{c | id: c.id2}
    assert eventually(fn -> words(stored(two)["meta"]["rt"]) == ["doc two text A"] end)
    refute html =~ "Someone else rewrote"
    assert words(stored(c)["meta"]["rt"]) == ["one two B"]
  end

  test "a navigation that stays on the document keeps the log: B's change still merges", c do
    a = open(c)
    b = open(c)
    b_saves_rt(b, c, "<p>one two</p><p>B para</p>", ["one two", "B para"])
    page = got(page(), next_push(a), false)

    render_patch(a, "#{c.root}/_desk/#{c.type};#{c.id}")
    html = post_rt(a, "<p>one twoA</p>", seen(page))

    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["one twoA", "B para"] end)
    refute html =~ "Someone else rewrote"
  end
end
