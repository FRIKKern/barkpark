defmodule BarkparkWeb.Studio.TopRichTextHtmlBodyViewTest do
  @moduledoc """
  task-077fbe951d7c338e (#29063 review N1, N2): a legacy `body` the store
  holds as an HTML string is held under the lock, never merged
  (`Forms.HtmlBody`).

  N1: B adds a paragraph under A's post, where a block body would merge.
  The held view was A's words alone, so A's next key, or a Save, wrote
  over B's paragraph after one banner. The view is now the two merged,
  drawn as HTML: typing on it, or a Save, keeps both. The store stays a
  string.

  N2: B clears the body to nothing while A's page shows words. A's post
  was written over the clear. It is held, as a string body's change is.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  @paused ~s([data-test-id="doc-conflict-paused"])
  @line "Autosave is paused for body until you Save or Reload."

  setup %{conn: conn} do
    c = setup_doc(conn)
    put_body(c, "<p>body0</p>")
    c
  end

  defp put_body(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")

    content =
      if value == :drop,
        do: Map.delete(doc.content, "body"),
        else: Map.put(doc.content, "body", value)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
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

  defp rejoined(c, surface) do
    view = tab(c, surface)

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.put(&1, :editor_rt_rejoin, MapSet.new(["doc[body]"])))
    end)

    view
  end

  defp page(view) do
    [_, value] = Regex.run(~r/name="_bp_seen"[^>]*value="([^"]*)"/, render(view))
    value |> String.replace("&quot;", ~s(")) |> Jason.decode!() |> Map.put("v", 2)
  end

  defp took(view, seen) do
    %{proxy: {ref, _topic, _}} = view

    receive do
      {^ref, {:push_event, "bp:form-confirmed", %{oks: oks}}} ->
        took(view, Map.update(seen, "ok", oks, &Map.merge(&1, oks)))
    after
      300 -> seen
    end
  end

  defp types(view, html, seen),
    do:
      view
      |> element("#editor-form")
      |> render_change(%{
        "_target" => ["doc[body]"],
        "doc" => %{"title" => "T0", "body" => html},
        "_bp_seen" => Jason.encode!(seen)
      })

  defp body_post(view, html),
    do: send_post(view, "doc[body]", %{"doc" => %{"title" => "T0", "body" => html}})

  defp body(c), do: stored(c)["body"]

  # What the held page shows for the body: its editor draws the form.
  defp shown(view), do: form(view)["body"]

  defp race_b_adds_a_paragraph(c, surface) do
    c = Map.put(c, :surface, surface)
    {a, b} = {tab(c, surface), tab(c, surface)}

    html =
      inside(a, fn -> body_post(b, "<p>body0</p><p>B para</p>") end, fn ->
        body_post(a, "<p>body0 A</p>")
      end)

    assert body(c) == "<p>body0</p><p>B para</p>", "A's post was written over B's"
    assert html =~ "doc-conflict-banner", "A was not held"
    a
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} race, B adds a paragraph: the held view is A's words and B's paragraph",
         c do
      a = race_b_adds_a_paragraph(c, @surface)
      assert is_binary(shown(a)), "the view is not drawn as HTML: #{inspect(shown(a))}"
      assert shown(a) =~ "body0 A"
      assert shown(a) =~ "B para", "the held view dropped B's paragraph"
    end

    test "#{surface} race, B adds a paragraph: A types on the view, and both are written", c do
      a = race_b_adds_a_paragraph(c, @surface)
      body_post(a, String.replace(shown(a), "body0 A", "body0 AX"))
      assert eventually(fn -> is_binary(body(c)) and body(c) =~ "body0 AX" end)
      assert body(c) =~ "B para", "A's key wrote over B's paragraph"
    end

    test "#{surface} race, B adds a paragraph: A's Save writes both, as a string", c do
      a = race_b_adds_a_paragraph(c, @surface)

      a
      |> element("#editor-form")
      |> render_submit(%{"doc" => %{"title" => "T0", "body" => shown(a)}})

      assert is_binary(body(c))
      assert body(c) =~ "body0 A"
      assert body(c) =~ "B para", "A's Save wrote over B's paragraph"
    end

    test "#{surface} rejoin, B clears the body while A's page is away: A is held", c do
      a = tab(c, @surface)
      seen = took(a, page(a))
      types(a, "<p>body0 A1</p>", seen)
      assert body(c) == "<p>body0 A1</p>"
      seen = took(a, seen)
      GenServer.stop(a.pid, :normal)

      put_body(c, :drop)
      a2 = rejoined(c, @surface)
      html = types(a2, "<p>body0 A1 A7</p>", seen)
      assert body(c) in [nil, ""], "A's key was written over B's clear: #{inspect(body(c))}"
      assert html =~ "doc-conflict-banner", "A was not held"
      assert has_element?(a2, @paused, @line)
    end

    test "#{surface} race, B clears the body under A's post: A is held", c do
      a = tab(c, @surface)

      # B's clear (an API write: the body key gone) lands inside A's post.
      clear = fn -> Task.await(Task.async(fn -> put_body(c, :drop) end)) end
      html = inside(a, clear, fn -> body_post(a, "<p>body0 A</p>") end)

      assert body(c) in [nil, ""], "A's post was written over B's clear: #{inspect(body(c))}"
      assert html =~ "doc-conflict-banner", "A was not held"
    end

    test "#{surface} a body never set: one editor's first words are written, never held", c do
      put_body(c, :drop)
      a = tab(c, @surface)
      html = body_post(a, "<p>first</p>")
      assert eventually(fn -> body(c) == "<p>first</p>" end)
      refute html =~ "doc-conflict-banner", "a lone editor was held"
      html = body_post(a, "<p>first second</p>")
      assert eventually(fn -> body(c) == "<p>first second</p>" end)
      refute html =~ "doc-conflict-banner", "a lone editor was held"
    end
  end
end
