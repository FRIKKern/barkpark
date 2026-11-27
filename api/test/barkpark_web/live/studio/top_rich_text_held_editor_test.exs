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

  defp drop_body(c) do
    {doc, _, _} = Barkpark.Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Barkpark.Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.delete(doc.content, "body")
        },
        "production"
      )
  end

  # The page's `_bp_seen` as the form drew it.
  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    value |> String.replace("&quot;", ~s(")) |> Jason.decode!() |> Map.put("v", 2)
  end

  # LiveViewTest always joins with `_mounts: 0`: the state a socket that
  # mounted as a rejoin has after its load (`TextConfirmed.loaded/1`).
  defp rejoined(view) do
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :editor_rt_rejoin, MapSet.new(["doc[body]"])))
    end)
  end

  defp put_body(c, text) do
    {doc, _, _} = Barkpark.Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Barkpark.Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "body", [block("b1", text)])
        },
        "production"
      )
  end

  for surface <- [:desk, :studio] do
    # The #29054 rig, case (b): B saves while A's page is away; A's next key
    # on the page it kept is held, and the body drew its read-only branch.
    test "#{surface}: held on a rejoin, the body keeps its editor and its input", c do
      c = Map.put(c, :surface, unquote(surface))
      a = open(c)
      seen = page(a)
      GenServer.stop(a.pid, :normal)
      put_body(c, "body0 B5")

      a2 = open(c)
      rejoined(a2)

      html =
        send_post(a2, "doc[body]", %{
          "doc" => %{"title" => "T0", "body" => "<p>body0 A7</p>"},
          "_bp_seen" => Jason.encode!(seen)
        })

      assert body(c) == ["body0 B5"]
      assert html =~ "doc-conflict-banner"
      refute html =~ "cannot edit", "the held body drew its read-only branch"
      assert has_element?(a2, @editor)
      assert has_element?(a2, @input)
      assert form(a2)["body"] =~ "body0 A7"
    end

    # A doc with no body draws "" for it (`Content.Forms.classic_form_value/4`,
    # forms.ex:681), so the form always holds the field's HTML shape, and the
    # held view's shape is read from the schema field anyway. A post there is
    # written as posted: the store holds HTML, not blocks, and nothing holds
    # it (the rejoin case: task-bb19ab06ab1e87b2).
    test "#{surface}: a doc that had no body: the form draws \"\", and a post keeps the editor and its input",
         c do
      drop_body(c)
      c = Map.put(c, :surface, unquote(surface))
      {a, b} = {open(c), open(c)}
      assert form(a)["body"] == ""

      html =
        inside(a, fn -> body_post(b, "<p>bodB</p>") end, fn -> body_post(a, "<p>bodA</p>") end)

      refute html =~ "cannot edit", "the body drew its read-only branch"
      assert has_element?(a, @editor)
      assert has_element?(a, @input)
      assert is_binary(form(a)["body"])
    end

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
