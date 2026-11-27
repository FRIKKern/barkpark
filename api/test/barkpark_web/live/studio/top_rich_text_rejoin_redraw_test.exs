defmodule BarkparkWeb.Studio.TopRichTextRejoinRedrawTest do
  @moduledoc """
  task-7234490778404641 (#29054 r2 review, H5): A's page rejoined while B
  saved the body, so A's body is held. Then a redraw of the form (B saving
  another top-level rich text, or a desk paste into a widget field) sends
  the page the digest of each rich text it draws. That also took the held
  body out of the rejoin set, so A's next key was written over B's body,
  with no banner. A held rich text stays in the rejoin set across a redraw:
  the page draws A's held words, not the store's.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])
  @paused ~s([data-test-id="doc-conflict-paused"])
  @line "Autosave is paused for body until you Save or Reload."

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, schema} = Content.get_schema(c.type, "production")

    fields =
      schema.fields ++
        [
          %{"name" => "summary", "title" => "summary", "type" => "richText"},
          %{
            "name" => "reviewer",
            "title" => "reviewer",
            "type" => "reference",
            "refType" => c.type
          }
        ]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => c.type,
          "title" => "Object rich text",
          "visibility" => "public",
          "fields" => fields
        },
        "production"
      )

    put_field(c, "summary", [block("s1", "sum0")])
    c
  end

  defp h(words),
    do: Content.PortableText.to_html(Enum.with_index(words, &block("b#{&2 + 1}", &1)))

  defp body(c), do: words(stored(c)["body"])

  defp put_field(c, key, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, key, value)
        },
        "production"
      )
  end

  defp open_tab(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  # LiveViewTest always joins with `_mounts: 0`: the rejoin is the state
  # `TextConfirmed.loaded/1` gives a socket that mounted as one.
  defp rejoined(c, surface) do
    view = open_tab(c, surface)

    :sys.replace_state(view.pid, fn state ->
      update_in(
        state.socket.assigns,
        &Map.put(&1, :editor_rt_rejoin, MapSet.new(["doc[body]", "doc[summary]"]))
      )
    end)

    view
  end

  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    value |> String.replace("&quot;", ~s(")) |> Jason.decode!() |> Map.put("v", 2)
  end

  # The digests the page takes from what the server pushed it.
  defp took(view, seen) do
    %{proxy: {ref, _topic, _}} = view

    receive do
      {^ref, {:push_event, "bp:form-confirmed", %{oks: oks}}} ->
        took(view, Map.update(seen, "ok", oks, &Map.merge(&1, oks)))
    after
      300 -> seen
    end
  end

  defp post(view, target, fields, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => Map.merge(%{"title" => "T0"}, fields),
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp types(view, words, seen), do: post(view, "doc[body]", %{"body" => h(words)}, seen)

  # A typed " A1" and it landed; the socket dropped, and B saved B5 while
  # A was away. A's page rejoins and A types " A7": held.
  defp held(c, surface) do
    a = open_tab(c, surface)
    seen = took(a, page(a))
    types(a, ["body0 A1"], seen)
    assert body(c) == ["body0 A1"]
    seen = took(a, seen)
    GenServer.stop(a.pid, :normal)
    put_field(c, "body", [block("b1", "body0 A1 B5")])
    a2 = rejoined(c, surface)
    types(a2, ["body0 A1 A7"], seen)
    assert body(c) == ["body0 A1 B5"]
    assert has_element?(a2, @paused, @line)
    {a2, seen}
  end

  # B's page posts the body it draws, as the store holds it.
  defp b_saves_summary(c, surface, body \\ ["body0 A1 B5"]) do
    b = open_tab(c, surface)
    post(b, "doc[summary]", %{"body" => h(body), "summary" => "<p>sum0 B</p>"}, page(b))
    assert body(c) == body
    assert words(stored(c)["summary"]) == ["sum0 B"]
  end

  defp still_held(c, a2, seen) do
    render(a2)
    html = types(a2, ["body0 A1 A7 A8"], took(a2, seen))
    assert body(c) == ["body0 A1 B5"], "A's key was written over B's body"
    assert html =~ "doc-conflict-banner"
    assert has_element?(a2, @banner)
    assert has_element?(a2, @paused, @line)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface}: held body, then B saves another rich text: A's next key stays held", c do
      {a2, seen} = held(c, @surface)
      gen = :sys.get_state(a2.pid).socket.assigns.editor_form_gen
      b_saves_summary(c, @surface)
      render(a2)
      assert :sys.get_state(a2.pid).socket.assigns.editor_form_gen != gen, "no redraw: no test"
      still_held(c, a2, seen)
    end

    test "#{surface}: rejoined, nothing held yet, then B saves another rich text: A types on the store, written",
         c do
      a2 = rejoined(c, @surface)
      seen = page(a2)
      b_saves_summary(c, @surface, ["body0"])
      render(a2)
      html = types(a2, ["body0 A9"], took(a2, seen))
      assert body(c) == ["body0 A9"]
      refute html =~ "doc-conflict-banner", "a clean rejoin was held"
    end
  end

  test "desk: held body, then A pastes a reference: A's next key stays held", c do
    {a2, seen} = held(c, :desk)
    gen = :sys.get_state(a2.pid).socket.assigns.editor_form_gen
    ref = %{"_ref" => c.id <> "-link", "_type" => "reference"}

    clip =
      Jason.encode!(%{
        "type" => "sanityClipboardItem",
        "isDocument" => false,
        "schemaTypeName" => "x",
        "value" => ref,
        "barkpark" => %{
          "kind" => "field",
          "field" => %{"name" => "from", "sig" => "reference:#{c.type}", "value" => ref}
        }
      })

    params = Map.take(BarkparkWeb.EditorPost.marks(a2), ["_bp_doc"])

    render_hook(
      a2,
      "desk-field-paste",
      Map.merge(params, %{"field" => "reviewer", "clip" => clip})
    )

    assert eventually(fn -> match?(%{"_ref" => _}, stored(c)["reviewer"]) end)
    assert :sys.get_state(a2.pid).socket.assigns.editor_form_gen != gen, "no redraw: no test"
    still_held(c, a2, seen)
  end
end
