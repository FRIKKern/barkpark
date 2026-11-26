defmodule BarkparkWeb.Studio.ObjectRichTextNoSeenHoldTest do
  @moduledoc """
  task-0437fdf2f2a6ccba (split from task-64eed140345d8927, #28882 review):
  a post with no `_bp_rt_seen` (a page without bp-rt-remote.js) went
  through `ObjectRebase` path 2, where a clash is written as posted: B's
  word, saved under A's post, was gone with no banner. Over the object cap
  every merge is a clash, so it happened wherever B saved.

  The post is now read against the value that page shows, as a post with a
  number is read against its number: what the socket drew it at mount, or
  the page's own last post. A clash keeps the store and holds A with the
  banner. Another editor's save the socket took is not what the page shows
  (#28896 r1 review, B1).
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content

  @rb "Someone else rewrote"
  @name "doc[meta].rt"

  setup %{conn: conn} do
    {:ok,
     setup_doc(conn)
     |> then(fn
       {:ok, x} -> Map.new(x)
       x -> Map.new(x)
     end)}
  end

  defp ob(k), do: %{"_type" => "chip", "_key" => k, "v" => 1}

  defp rt(objects, text),
    do: [
      %{
        "_type" => "block",
        "_key" => "k1",
        "style" => "normal",
        "markDefs" => [],
        "children" =>
          [%{"_type" => "span", "_key" => "s1", "text" => text, "marks" => []}] ++ objects
      },
      block("k2", "anchor")
    ]

  defp put_rt(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = Map.update(doc.content || %{}, "meta", %{"rt" => value}, &Map.put(&1, "rt", value))

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp text_of(blocks), do: blocks |> hd() |> Map.get("children") |> hd() |> Map.get("text")

  # A's post with no `_bp_rt_seen`; B (an API write) rewrites the same
  # letter inside it.
  defp clash(c, objects, surface) do
    c = Map.put(c, :surface, surface)
    put_rt(c, rt(objects, "one two three"))
    a = open(c)

    html =
      Barkpark.Content.PortableText.to_html(rt(objects, "one twA three"))

    h =
      inside(a, fn -> put_rt(c, rt(objects, "one twB three")) end, fn ->
        send_post(a, @name, %{"doc[meta].label" => "l0", @name => html})
      end)

    {a, h, stored(c)["meta"]["rt"]}
  end

  for surface <- [:desk, :studio],
      {n, label} <- [{2, "under the cap"}, {6_000, "over the cap"}] do
    @tag timeout: 300_000
    test "#{surface} #{label}: a no-seen post clashing with B's word keeps B's and holds A with the banner",
         c do
      {a, h, stored} = clash(c, for(i <- 1..unquote(n), do: ob("o#{i}")), unquote(surface))

      assert text_of(stored) == "one twB three"
      assert h =~ @rb
      held = :sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{}
      assert Map.has_key?(held, @name)
      assert text_of(held[@name].view) == "one twA three"
    end
  end

  # #28896 r1 review, B1: the page's editor sits in a `phx-update="ignore"`
  # wrapper, so B's save, taken by A's socket into `editor_form`, never
  # reaches what A's page shows. Read against `editor_form`, A's post wrote
  # the old "anchor" over B's.
  for surface <- [:desk, :studio], how <- [:auto, :save] do
    test "#{surface} #{how}: B's other-block save already taken, A types on what it shows: merged, B's kept",
         c do
      c = Map.put(c, :surface, unquote(surface))
      put_rt(c, [block("k1", "one two"), block("k2", "anchor")])
      a = open(c)
      put_rt(c, [block("k1", "one two"), block("k2", "anchor B")])
      assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["one two", "anchor B"] end)

      fields = %{
        "doc[meta].label" => "l0",
        @name =>
          Barkpark.Content.PortableText.to_html([block("k1", "ONE two"), block("k2", "anchor")])
      }

      h =
        case unquote(how) do
          :auto ->
            send_post(a, @name, fields)

          :save ->
            a
            |> element("#editor-form")
            |> render_submit(Map.merge(%{"doc" => %{"title" => "T0"}}, fields))
        end

      assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["ONE two", "anchor B"] end)
      refute h =~ @rb
    end
  end

  test "desk: A's second post is read against A's first, not against B's save it never showed",
       c do
    c = Map.put(c, :surface, :desk)
    put_rt(c, [block("k1", "one two"), block("k2", "anchor")])
    a = open(c)

    html = fn t1 ->
      Barkpark.Content.PortableText.to_html([block("k1", t1), block("k2", "anchor")])
    end

    send_post(a, @name, %{"doc[meta].label" => "l0", @name => html.("ONE two")})
    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["ONE two", "anchor"] end)

    put_rt(c, [block("k1", "ONE two"), block("k2", "anchor B")])
    assert eventually(fn -> words(form(a)["meta"]["rt"]) == ["ONE two", "anchor B"] end)

    h = send_post(a, @name, %{"doc[meta].label" => "l0", @name => html.("ONE TWO")})
    assert eventually(fn -> words(stored(c)["meta"]["rt"]) == ["ONE TWO", "anchor B"] end)
    refute h =~ @rb
  end

  test "desk: a no-seen post with no other save is written as posted, no banner", c do
    c = Map.put(c, :surface, :desk)
    put_rt(c, rt([ob("o1")], "one two three"))
    a = open(c)
    html = Barkpark.Content.PortableText.to_html(rt([ob("o1")], "one twA three"))
    h = send_post(a, @name, %{"doc[meta].label" => "l0", @name => html})
    assert eventually(fn -> text_of(stored(c)["meta"]["rt"]) == "one twA three" end)
    refute h =~ @rb
  end

  test "desk: a no-seen post B's save merges with is written merged, no banner", c do
    c = Map.put(c, :surface, :desk)
    put_rt(c, rt([], "one two three"))
    a = open(c)
    html = Barkpark.Content.PortableText.to_html(rt([], "ONE two three"))

    h =
      inside(a, fn -> put_rt(c, rt([], "one two THREE")) end, fn ->
        send_post(a, @name, %{"doc[meta].label" => "l0", @name => html})
      end)

    assert text_of(stored(c)["meta"]["rt"]) == "ONE two THREE"
    refute h =~ @rb
  end
end
