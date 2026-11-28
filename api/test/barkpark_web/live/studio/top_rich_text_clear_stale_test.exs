defmodule BarkparkWeb.Studio.TopRichTextClearStaleTest do
  @moduledoc """
  B removes a whole top-level Portable Text body; A's socket takes it, but
  A's page has not drawn it: A's next post carries the old seen.

    * P9 (task-8bdc4000481ed6b2, #29299 review): A wrote first, then B
      empties the body, then A's stale post before the confirm.
    * clear-stale (task-d91ccf6bf316123a, #29295 review): the field holds
      X, B clears it, A's stale post "X A".
    * W_empty (task-7555428e0a2617fe, #29292 review): B fills the empty
      field, A's page draws it, B clears it to `[]`, a writer stores `[]`
      again inside A's stale Save.

  B's removal is kept and A held, with the banner, as for any other change
  of B's A's page has not drawn.
  """
  use BarkparkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText
  alias Barkpark.Content
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, schema} = Content.get_schema(c.type, "production")

    fields =
      Enum.map(schema.fields, fn
        %{"name" => "body"} = f -> Map.put(f, "format", "portableText")
        f -> f
      end)

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

    c
  end

  defp tab(c, surface) do
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

  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  # B's write through the store.
  defp put_body(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{
          "doc_id" => "drafts." <> c.id,
          "title" => doc.title,
          "content" => Map.put(doc.content, "body", value)
        },
        "production"
      )
  end

  defp b_clears(c, a) do
    put_body(c, nil)

    assert eventually(fn -> form(a)["body"] in [nil, "", []] end),
           "A's socket did not take B's clear"
  end

  defp post(view, :autosave, html, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[body]"],
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp post(view, :save, html, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp body_words(c) do
    case stored(c)["body"] do
      l when is_list(l) -> words(l)
      other -> other
    end
  end

  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp cleared?(c), do: body_words(c) in [nil, [], ""]

  for surface <- [:desk, :studio], how <- [:autosave, :save] do
    @surface surface
    @how how

    test "#{surface} #{how} P9: A writes, B empties the body, A's stale post: B's removal kept, A held",
         c do
      put_body(c, [block("b1", "body0"), block("b2", "second")])
      a = tab(c, @surface)
      seen = page(a)
      post(a, @how, "<p>body0 A</p><p>second</p>", seen)
      assert body_words(c) == ["body0 A", "second"]
      b_clears(c, a)

      html = post(a, @how, "<p>body0 A A2</p><p>second</p>", seen)

      # Before: ["body0 A A2", "second"] written over B's removal, no banner.
      assert cleared?(c), "A's words were written over B's removal: #{inspect(body_words(c))}"
      assert held(a) == ["doc[body]"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} #{how} clear-stale: the body holds X, B clears it, A's stale X A: B's clear kept, A held",
         c do
      put_body(c, [block("b1", "X")])
      a = tab(c, @surface)
      seen = page(a)
      b_clears(c, a)

      html = post(a, @how, "<p>X A</p>", seen)

      assert cleared?(c), "A's words were written over B's clear: #{inspect(body_words(c))}"
      assert held(a) == ["doc[body]"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} #{how} W_empty: B fills, A draws, B clears to [], [] again inside A's post: B's clear kept, A held",
         c do
      put_body(c, nil)
      a = tab(c, @surface)
      put_body(c, [block("k9", "B1")])
      assert eventually(fn -> inspect(form(a)["body"]) =~ "B1" end)
      render(a)
      seen = page(a)
      put_body(c, [])
      assert eventually(fn -> form(a)["body"] in [nil, "", []] end)

      html =
        inside(a, fn -> Task.await(Task.async(fn -> put_body(c, []) end)) end, fn ->
          post(a, @how, "<p>B1 A</p>", seen)
        end)

      assert cleared?(c), "A's words were written over B's clear: #{inspect(body_words(c))}"
      assert held(a) == ["doc[body]"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface} #{how} clear-stale add: B clears X, A's stale post keeps X and adds a block: merged, X stays removed",
         c do
      put_body(c, [block("b1", "X")])
      a = tab(c, @surface)
      seen = page(a)
      b_clears(c, a)

      post(a, @how, "<p>X</p><p>Y A</p>", seen)

      # Before: ["X", "Y A"], B's removal of X written back.
      assert body_words(c) == ["Y A"]
      assert held(a) == []
    end

    test "#{surface} #{how} control: A's page drew B's clear, A types first words: written", c do
      put_body(c, [block("b1", "X")])
      a = tab(c, @surface)
      b_clears(c, a)
      render(a)

      html = post(a, @how, "<p>A new</p>", page(a))

      assert body_words(c) == ["A new"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} #{how} control: A writes twice on one draw, nobody else saves: written", c do
      put_body(c, [block("b1", "body0"), block("b2", "second")])
      a = tab(c, @surface)
      seen = page(a)
      post(a, @how, "<p>body0 A</p><p>second</p>", seen)

      html = post(a, @how, "<p>body0 A A2</p><p>second</p>", seen)

      assert body_words(c) == ["body0 A A2", "second"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end
  end
end
