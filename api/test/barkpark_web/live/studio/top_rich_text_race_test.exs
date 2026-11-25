defmodule BarkparkWeb.Studio.TopRichTextRaceTest do
  @moduledoc """
  task-fa07c64d344638fb: a top-level rich text (`doc[body]`), two tabs
  posting it at once. B's save lands after A's post is read and before A's
  write (`inside/3`), so A's socket reads A's post as current, and A's post
  was written as posted: B's word was gone with no banner.

  A top-level rich text editor is remounted on a value the socket draws
  (its wrapper id carries the form generation), so the page shows what the
  socket last drew: A's post is read under the lock against that. The store
  still holds it, and the post is written; it moved, and the post is merged
  onto it; a clash keeps the store and holds A with the banner.
  """
  use BarkparkWeb.ConnCase, async: false

  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  @rb "Someone else rewrote"

  setup %{conn: conn}, do: setup_doc(conn)

  defp body_post(view, html),
    do: send_post(view, "doc[body]", %{"doc" => %{"title" => "T0", "body" => html}})

  defp body(c), do: words(stored(c)["body"])

  for surface <- [:desk, :studio] do
    test "#{surface}: both type in one word, B's save lands under A's post: held, B's words stored",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        inside(a, fn -> body_post(b, "<p>bodB</p>") end, fn -> body_post(a, "<p>body0A</p>") end)

      assert body(c) == ["bodB"]
      assert html =~ @rb
    end

    test "#{surface}: each types in a word of their own, B's save lands under A's post: both kept",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      body_post(b, "<p>one body0 two</p>")
      assert eventually(fn -> body(c) == ["one body0 two"] end)
      assert eventually(fn -> form(a)["body"] =~ "one body0 two" end)

      html =
        inside(a, fn -> body_post(b, "<p>one body0 TWO</p>") end, fn ->
          body_post(a, "<p>ONE body0 two</p>")
        end)

      assert body(c) == ["ONE body0 TWO"]
      refute html =~ @rb
    end

    test "#{surface}: held, then A types on its view: A's words written as typed, the hold ends",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        inside(a, fn -> body_post(b, "<p>bodB</p>") end, fn -> body_post(a, "<p>body0A</p>") end)

      assert html =~ @rb
      assert body(c) == ["bodB"]

      html = body_post(a, "<p>body0A more</p>")
      assert eventually(fn -> body(c) == ["body0A more"] end)
      refute html =~ @rb
      assert (:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{}) == %{}
    end

    test "#{surface}: no other save: A's body post is written as posted, no banner", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      html = body_post(a, "<p>body0 A</p>")
      assert eventually(fn -> body(c) == ["body0 A"] end)
      refute html =~ @rb
    end

    test "#{surface}: B's save already drawn, A types on it: written, no banner", c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      body_post(b, "<p>body0 B</p>")
      assert eventually(fn -> form(a)["body"] =~ "body0 B" end)
      html = body_post(a, "<p>body0 B A</p>")
      assert eventually(fn -> body(c) == ["body0 B A"] end)
      refute html =~ @rb
    end
  end
end
