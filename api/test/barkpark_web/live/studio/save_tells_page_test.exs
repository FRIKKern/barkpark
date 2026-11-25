defmodule BarkparkWeb.Studio.SaveTellsPageTest do
  # task-ac7531b991f6bae1: another editor's save lands during A's explicit
  # Save. The Save's reload takes it into the socket, but the page was never
  # told: A's form kept the old text, and A's next Save wrote it over B's
  # words with no banner (#28832 review, S1). After the reload the page is
  # sent every value that landed during the Save, except the fields it holds.
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  @banner "Someone else rewrote"

  setup %{conn: conn}, do: setup_doc(conn)

  # The explicit Save, as the page submits the whole form.
  defp save(view, fields) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0"},
      "doc[meta].label" => fields[:label] || "l0",
      "doc[meta].rt" => fields[:rt] || "<p>one two</p>",
      "_bp_seen" => Jason.encode!(Map.put(fields[:seen] || %{}, "v", 2)),
      "_bp_rt_seen" => ["doc[meta].rt|#{fields[:rt_seen] || 0}"]
    })
  end

  defp b_saves_label(b, label),
    do:
      send_post(b, "doc[meta].label", %{
        "doc[meta].label" => label,
        "doc[meta].rt" => "<p>one two</p>"
      })

  for surface <- [:desk, :studio] do
    test "#{surface}: A Saves the label, B's rich text lands inside: A's page is sent B's, and A's next Save keeps it",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html = b_saves_inside(a, b, "<p>one twB</p>", fn -> save(a, label: "lA") end)

      refute html =~ @banner
      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      assert stored(c)["meta"]["label"] == "lA"

      # On main: no push, the page keeps "one two".
      assert_push_event(
        a,
        "bp:rt-remote",
        %{values: %{"doc[meta].rt" => %{html: html_b, seq: seq}}},
        2_000
      )

      assert html_b =~ "one twB"

      # The next Save, from a page that drew it, or one still on the old text.
      save(a, label: "lAA", rt: html_b, rt_seen: seq)
      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      save(a, label: "lAAA")
      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      assert stored(c)["meta"]["label"] == "lAAA"
    end

    test "#{surface}: A Saves the rich text, B's label lands inside: A's page is sent B's label",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html = inside(a, fn -> b_saves_label(b, "lB") end, fn -> save(a, rt: "<p>ONE two</p>") end)

      refute html =~ @banner
      assert stored(c)["meta"]["label"] == "lB"
      assert words(stored(c)["meta"]["rt"]) == ["ONE two"]

      # On main: no push; a focused label kept "l0" and the next Save wrote it back.
      assert_push_event(
        a,
        "bp:form-remote-values",
        %{values: %{"doc[meta].label" => %{value: "lB", was: "l0"}}},
        2_000
      )
    end

    test "#{surface}: a field the Save holds is not sent B's value over A's words", c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html = b_saves_inside(a, b, "<p>one twB</p>", fn -> save(a, rt: "<p>one twoA</p>") end)

      assert html =~ @banner
      assert words(stored(c)["meta"]["rt"]) == ["one twB"]

      # The hold's view (A's words), never B's stored value as the page's own.
      assert_push_event(a, "bp:rt-remote", %{values: %{"doc[meta].rt" => %{html: view}}}, 2_000)
      assert view =~ "one twoA"

      refute_push_event(
        a,
        "bp:rt-remote",
        %{values: %{"doc[meta].rt" => %{html: "<p>one twB</p>"}}},
        300
      )
    end

    # #28832 review, N1: a Save over a rich text still held from before
    # showed its banner and "Saved" together.
    test "#{surface}: a Save while a rich text is still held: the banner, no Saved", c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      b_saves_rt(b, c, "<p>one twB</p>", ["one twB"])
      post_rt(a, "<p>one twoA</p>", 0)

      assert_push_event(
        a,
        "bp:rt-remote",
        %{values: %{"doc[meta].rt" => %{html: view, seq: seq}}},
        2_000
      )

      html = save(a, label: "lA", rt: view, rt_seen: seq)

      assert html =~ @banner
      refute (:sys.get_state(a.pid).socket.assigns.flash || %{})["info"] == "Saved"
      assert words(stored(c)["meta"]["rt"]) == ["one twB"]
      assert stored(c)["meta"]["label"] == "lA"
    end

    test "#{surface}: a lone Save sends nothing", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)

      save(a, label: "lA", rt: "<p>one two three</p>")

      assert stored(c)["meta"]["label"] == "lA"
      refute_push_event(a, "bp:form-remote-values", _, 300)
      refute_push_event(a, "bp:rt-remote", _, 100)
    end
  end
end
