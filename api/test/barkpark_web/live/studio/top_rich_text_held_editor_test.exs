defmodule BarkparkWeb.Studio.TopRichTextHeldEditorTest do
  @moduledoc """
  task-f69efe9a4365aeb5: a held top-level rich text (`doc[body]`) was put
  in the form as Portable Text blocks, the shape a row's or an object's
  rich text holds. The top-level form holds the HTML its editor draws, so
  the field drew its read-only branch ("stored as block content, which the
  rich-text editor (HTML) cannot edit"): no editor, no `doc[body]` input,
  and a Save in the browser never posted A's held words.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  @moduletag :studio_live

  @rb "Someone else rewrote"
  @editor ~s([data-field="body"] bp-rich-text-editor)
  @input ~s(#editor-form input[name="doc[body]"])

  setup %{conn: conn}, do: setup_doc(conn)

  defp body_post(view, html),
    do: send_post(view, "doc[body]", %{"doc" => %{"title" => "T0", "body" => html}})

  defp body(c), do: words(stored(c)["body"])

  for surface <- [:desk, :studio] do
    test "#{surface}: held, the body keeps its editor and its input, holding A's words as HTML",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      html =
        inside(a, fn -> body_post(b, "<p>bodB</p>") end, fn -> body_post(a, "<p>body0A</p>") end)

      assert html =~ @rb
      assert body(c) == ["bodB"]

      refute html =~ "cannot edit", "the held body drew its read-only branch"
      assert has_element?(a, @editor)
      assert has_element?(a, @input)

      held = :sys.get_state(a.pid).socket.assigns.editor_form["body"]
      assert is_binary(held)
      assert held =~ "body0A"
    end

    test "#{surface}: held, a Save of what the page shows writes A's words and ends the banner",
         c do
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}

      _ =
        inside(a, fn -> body_post(b, "<p>bodB</p>") end, fn -> body_post(a, "<p>body0A</p>") end)

      assert has_element?(a, @input)

      # The browser posts the form's inputs: the held editor's HTML.
      held = :sys.get_state(a.pid).socket.assigns.editor_form["body"]

      a
      |> element("#editor-form")
      |> render_submit(%{"doc" => %{"title" => "T0", "body" => held}})

      assert body(c) == ["body0A"]
      refute render(a) =~ @rb
    end
  end
end
