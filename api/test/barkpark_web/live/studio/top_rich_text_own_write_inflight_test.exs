defmodule BarkparkWeb.Studio.TopRichTextOwnWriteInflightTest do
  @moduledoc """
  task-5aa3a09baf4703c2 (#29259 r2 review, D1, D2). A writes the body; the
  confirm of that write has not reached A's page, so A's next post still
  names the value A typed on before it. B saves a block in that window:
  after A's write (D1) or inside it (D2). A's next post was read against
  B's store, and wrote B's block back to the old text with no banner.
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

    set_body(c, two("body0", "second"))
    c
  end

  defp two(a, b), do: [block("b1", a), block("b2", b)]
  defp html(a, b), do: "<p>#{a}</p><p>#{b}</p>"

  defp set_body(c, value) do
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

  defp body(c), do: words(stored(c)["body"] || [])
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

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

  # B's save, and A's socket taking it.
  defp b_saves(c, a, value) do
    set_body(c, value)
    [_, last] = words(value)

    assert eventually(fn -> inspect(form(a)["body"]) =~ last end),
           "A's socket did not take B's save"
  end

  defp post(view, "autosave", html, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[body]"],
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp post(view, "save", html, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  # A's page draws B's first save, so A types on it.
  defp a_on_b0(c, surface) do
    a = tab(c, surface)
    b_saves(c, a, two("body0", "second B0"))
    render(a)
    a
  end

  for surface <- [:desk, :studio], how <- ["autosave", "save"] do
    @surface surface
    @how how

    test "#{surface} #{how} D1: B saves after A's write, before its confirm; A's next post keeps B's block",
         c do
      a = a_on_b0(c, @surface)
      seen = page(a)
      post(a, @how, html("body0 A", "second B0"), seen)
      assert body(c) == ["body0 A", "second B0"]
      b_saves(c, a, two("body0 A", "second B1"))

      html = post(a, @how, html("body0 A A2", "second B0"), seen)

      # Before: ["body0 A A2", "second B0"], B's "second B1" written back, no
      # banner. Now A's edit is merged with B's.
      assert body(c) == ["body0 A A2", "second B1"],
             "B's block was written back: #{inspect(body(c))}"

      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} #{how} D2: B saves inside A's write; A's next post keeps B's block", c do
      a = a_on_b0(c, @surface)
      seen = page(a)

      inside(
        a,
        fn -> Task.await(Task.async(fn -> set_body(c, two("body0", "second B1")) end)) end,
        fn ->
          post(a, @how, html("body0 A", "second B0"), seen)
        end
      )

      # The write itself merges.
      assert body(c) == ["body0 A", "second B1"]

      html = post(a, @how, html("body0 A A2", "second B0"), seen)

      assert body(c) == ["body0 A A2", "second B1"],
             "B's block was written back: #{inspect(body(c))}"

      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} #{how} control: A writes twice before its confirm, nobody else saves: written as typed",
         c do
      a = a_on_b0(c, @surface)
      seen = page(a)
      post(a, @how, html("body0 A", "second B0"), seen)
      html = post(a, @how, html("body0 A A2", "second B0 A"), seen)
      assert body(c) == ["body0 A A2", "second B0 A"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} #{how} control: the confirm of A's write landed, then B saves: B's block kept",
         c do
      a = a_on_b0(c, @surface)
      post(a, @how, html("body0 A", "second B0"), page(a))
      seen = page(a)
      b_saves(c, a, two("body0 A", "second B1"))
      post(a, @how, html("body0 A A2", "second B0"), seen)
      assert "second B1" in body(c), "B's block was written back: #{inspect(body(c))}"
    end
  end
end
