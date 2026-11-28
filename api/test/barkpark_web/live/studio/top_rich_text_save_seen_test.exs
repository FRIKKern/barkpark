defmodule BarkparkWeb.Studio.TopRichTextSaveSeenTest do
  @moduledoc """
  task-6b8ad69face66171 (#29174 review, R2s and R3). B saves the body and
  A's socket takes it, but A's Save goes out with the `_bp_seen` of the
  value A's page still showed. The autosave reads such a post against that
  value (`TextConfirmed.page_base/4`, task-a368aa61eb491d9f) and holds A.
  The Save read it against the row the socket last took (B's), so A's
  words were written over B's fill (R2s) or over B's clear (R3), with no
  banner. A Save whose seen is the stored value still writes.

  A post written as typed ends the log of values the page may still show
  (#29259 review, T6s, T6r, T6aa): its next post, sent before the confirm,
  is A's own, not a stale one. A merge with B's save keeps it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn}, do: setup_doc(conn)

  defp pt!(c) do
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
  end

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

  defp body(c), do: stored(c)["body"]
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

  # The page's `_bp_seen` as bp-array-focus.js keeps it (`PageSeen`).
  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp autosave(view, html, seen) do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => ["doc[body]"],
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  # The explicit Save, as the page submits the whole form.
  defp save(view, html, seen) do
    view
    |> element("#editor-form")
    |> render_submit(%{
      "doc" => %{"title" => "T0", "body" => html},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  # B's save of the body, taken by A's socket before A's page draws it.
  defp b_saves(c, a, value) do
    put_body(c, value)
    assert eventually(fn -> body(c) == value end)

    assert eventually(fn ->
             is_list((:sys.get_state(a.pid).socket.assigns[:editor_rt_took] || %{})["doc[body]"])
           end)
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} R2s: A's page shows the body cleared; B fills it first; A's stale Save: B kept, A held",
         c do
      pt!(c)
      put_body(c, [block("b1", "body0")])
      a = tab(c, @surface)
      autosave(a, "<p></p>", page(a))
      assert body(c) == []
      seen = page(a)
      b_saves(c, a, [block("k9", "B")])

      html = save(a, "<p>new A</p>", seen)

      # On main: ["new A"], no banner.
      assert words(body(c)) == ["B"]
      assert held(a) == ["doc[body]"]
      assert html =~ "doc-conflict-banner"
      assert has_element?(a, @banner)
    end

    test "#{surface} R3: B clears the body first; A's stale Save edits it: B's clear kept, A held",
         c do
      pt!(c)
      put_body(c, [block("b1", "body0")])
      a = tab(c, @surface)
      seen = page(a)
      b_saves(c, a, [])

      html = save(a, "<p>body0 A</p>", seen)

      # On main: ["body0 A"], no banner.
      assert body(c) == []
      assert held(a) == ["doc[body]"]
      assert html =~ "doc-conflict-banner"
    end

    test "#{surface}: B fills other blocks; A's stale Save edits its own block: both kept", c do
      pt!(c)
      put_body(c, [block("b1", "body0"), block("b2", "second")])
      a = tab(c, @surface)
      seen = page(a)
      b_saves(c, a, [block("b1", "body0"), block("b2", "second B")])

      save(a, "<p>body0 A</p><p>second</p>", seen)

      assert eventually(fn -> words(body(c)) == ["body0 A", "second B"] end)
      assert held(a) == []
    end

    test "#{surface} control: a Save typed after B's save was drawn is written", c do
      pt!(c)
      put_body(c, [block("b1", "body0")])
      a = tab(c, @surface)
      b_saves(c, a, [block("b1", "body0 B")])
      render(a)

      html = save(a, "<p>body0 B A</p>", page(a))

      assert words(body(c)) == ["body0 B A"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A's own Saves before their confirm lands are written as typed", c do
      pt!(c)
      put_body(c, [block("b1", "body0")])
      a = tab(c, @surface)
      seen = page(a)

      save(a, "<p>body0 A1</p>", seen)
      html = save(a, "<p>body0 A1 A2</p>", seen)

      assert words(body(c)) == ["body0 A1 A2"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} T6s: B changes the body and reverts it; A Saves twice before the confirm: written",
         c do
      pt!(c)
      put_body(c, [block("b1", "body0")])
      a = tab(c, @surface)
      b_saves(c, a, [block("b1", "body0 B")])
      b_saves(c, a, [block("b1", "body0")])
      render(a)
      seen = page(a)

      save(a, "<p>body0 a</p>", seen)
      html = save(a, "<p>body0 a b</p>", seen)

      # On #29259 r1: ["body0 a"], A held against A's own Save.
      assert words(body(c)) == ["body0 a b"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} T6r: A deletes B's words; an autosave and a Save before its confirm: written",
         c do
      pt!(c)
      put_body(c, [block("b1", "body0")])
      a = tab(c, @surface)
      b_saves(c, a, [block("b1", "body0 B")])
      render(a)
      autosave(a, "<p>body0</p>", page(a))
      assert words(body(c)) == ["body0"]
      seen = page(a)

      autosave(a, "<p>body0 a</p>", seen)
      html = save(a, "<p>body0 a b</p>", seen)

      # On #29259 r1: ["body0 a"], A held against A's own autosave.
      assert words(body(c)) == ["body0 a b"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} T6aa: B changes the body and reverts it; two autosaves before the confirm: written",
         c do
      pt!(c)
      put_body(c, [block("b1", "body0")])
      a = tab(c, @surface)
      b_saves(c, a, [block("b1", "body0 B")])
      b_saves(c, a, [block("b1", "body0")])
      render(a)
      seen = page(a)

      autosave(a, "<p>body0 a</p>", seen)
      html = autosave(a, "<p>body0 a b</p>", seen)

      # On main: ["body0 a"], A held against A's own autosave.
      assert words(body(c)) == ["body0 a b"]
      assert held(a) == []
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: after a merge with B, A's next stale Save keeps B's block, A held",
         c do
      pt!(c)
      put_body(c, [block("b1", "body0"), block("b2", "second")])
      a = tab(c, @surface)
      seen = page(a)
      b_saves(c, a, [block("b1", "body0"), block("b2", "second B")])

      save(a, "<p>body0 A</p><p>second</p>", seen)
      assert eventually(fn -> words(body(c)) == ["body0 A", "second B"] end)
      html = save(a, "<p>body0 A A2</p><p>second</p>", seen)

      # Read against the store, it would write "second" over B's block.
      assert words(body(c)) == ["body0 A", "second B"]
      assert held(a) == ["doc[body]"]
      assert html =~ "doc-conflict-banner"
    end
  end
end
