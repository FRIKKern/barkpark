defmodule BarkparkWeb.Studio.ObjectRichTextSaveRaceTest do
  # task-8f15f5c9c15ce748: the explicit Save (phx-submit) of a rich text in
  # an object skipped `RichTextRemote.UnderLock`. B's save landing after A's
  # Save is read and before its write (`b_saves_inside/4`) was written over
  # as sent, with no banner, as the autosave was before #28792.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  setup %{conn: conn}, do: setup_doc(conn)

  # The explicit Save, as the page submits the whole form.
  defp save_rt(view, html, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0"},
      "doc[meta].label" => "l0",
      "doc[meta].rt" => html,
      "_bp_rt_seen" => ["doc[meta].rt|#{seen}"]
    })
  end

  for surface <- [:desk, :studio] do
    test "#{surface}: both type in one word, B's save lands under A's Save: held, B's words stored",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html = b_saves_inside(a, b, "<p>one twB</p>", fn -> save_rt(a, "<p>one twoA</p>", 0) end)

      # On main: "one twoA", no banner, B's words gone.
      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      assert html =~ "Someone else rewrote"

      assert_push_event(a, "bp:rt-remote", %{values: %{"doc[meta].rt" => %{html: view}}}, 2_000)
      assert view =~ "one twoA"
    end

    test "#{surface}: each types in a word of their own, B's save lands under A's Save: both kept",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html = b_saves_inside(a, b, "<p>one TWO</p>", fn -> save_rt(a, "<p>ONE two</p>", 0) end)

      # On main: "ONE two", B's TWO gone.
      assert words(stored(c)["meta"]["rt"]) == ["ONE TWO"]
      refute html =~ "Someone else rewrote"
    end

    test "#{surface}: A's Save leaves the rich text as it was, B's save lands under it: B's stored, no banner",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html = b_saves_inside(a, b, "<p>one twB</p>", fn -> save_rt(a, "<p>one two</p>", 0) end)

      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      refute html =~ "Someone else rewrote"
    end

    test "#{surface}: a lone Save of the rich text is saved as sent, no banner", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)

      html = save_rt(a, "<p>one two three</p>", 0)

      assert words(stored(c)["meta"]["rt"]) == ["one two three"]
      refute html =~ "Someone else rewrote"
    end
  end
end
