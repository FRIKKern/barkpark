defmodule BarkparkWeb.Studio.ObjectRichTextRowDigestCollisionTest do
  @moduledoc """
  task-9b705d11bf85560e: a row rich text's draws are kept by the digest of
  the HTML drawn (`RowDraws`, `CompositeField.drawn_digest/1`), and the page
  posts the digest of its draw (`_bp_rt_owner[]`). It was a 27-bit
  `:erlang.phash2/1`: `<p>row text 1120</p>` and `<p>row text 8568</p>`
  share one. A opens the row at the first; B's save of the second, taken by
  A's socket, took the first draw's place, so A's post typed on the first
  read as typed on B's and was written over it with no banner, like the
  'title 15779'/'title 19776' case #29073 fixed for TextConfirmed.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.Components.Fields.CompositeField

  @moduletag :studio_live

  @name "doc[meta].rows[0].rt"
  @rb "Someone else rewrote"
  @a_text "row text 1120"
  @b_text "row text 8568"

  setup %{conn: conn}, do: setup_doc(conn)

  defp put_rows(c, rows) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = put_in(doc.content, ["meta", "rows"], rows)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp row(text), do: [%{"_type" => "row", "_key" => "r1", "rt" => [block("w1", text)]}]
  defp row_words(c), do: words(hd(stored(c)["meta"]["rows"])["rt"])
  defp held(a), do: Map.keys(:sys.get_state(a.pid).socket.assigns[:editor_rt_held] || %{})

  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  defp a_posts(a, how, html) do
    fields = %{
      "doc[meta].label" => "l0",
      "doc[meta].rows[0]._type" => "row",
      "doc[meta].rows[0]._key" => "r1",
      @name => html,
      "_bp_rt_owner" => page_owners(a)
    }

    case how do
      :auto ->
        send_post(a, @name, fields)

      :save ->
        a
        |> element("#editor-form")
        |> render_submit(Map.merge(%{"doc" => %{"title" => "T0"}}, fields))
    end
  end

  test "the pair collides under phash2 as drawn: the probe below means something" do
    [a, b] = for t <- [@a_text, @b_text], do: CompositeField.drawn_html([block("w1", t)])
    refute a == b
    assert :erlang.phash2(a) == :erlang.phash2(b), "no phash2 collision: no test"
  end

  test "drawn_digest is the 64-bit digest TextConfirmed keeps" do
    html = CompositeField.drawn_html([block("w1", @a_text)])

    assert CompositeField.drawn_digest([block("w1", @a_text)]) ==
             BarkparkWeb.Studio.StudioLive.Handlers.TextConfirmed.digest(html)

    refute CompositeField.drawn_digest([block("w1", @a_text)]) ==
             CompositeField.drawn_digest([block("w1", @b_text)])
  end

  # A page drawn before the 64-bit digest posts the old number for its draw.
  defp legacy_owners(view, drawn_text) do
    old = :erlang.phash2(CompositeField.drawn_html([block("w1", drawn_text)]))

    for entry <- page_owners(view) do
      [name, key, _digest | _outer] = Jason.decode!(entry)
      Jason.encode!([name, key, old])
    end
  end

  for surface <- [:desk, :studio] do
    @tag timeout: 120_000
    test "#{surface}: a page posting the old number digest is read as before: B kept, A held",
         c do
      c = Map.put(c, :surface, unquote(surface))
      put_rows(c, row("one two"))
      a = open(c)
      put_rows(c, row("one twoB"))
      assert eventually(fn -> words(hd(form(a)["meta"]["rows"])["rt"]) == ["one twoB"] end)

      html =
        send_post(a, @name, %{
          "doc[meta].label" => "l0",
          "doc[meta].rows[0]._type" => "row",
          "doc[meta].rows[0]._key" => "r1",
          @name => "<p>one twoA</p>",
          "_bp_rt_owner" => legacy_owners(a, "one two")
        })

      assert row_words(c) == ["one twoB"], "B's row edit lost: #{inspect(row_words(c))}"
      assert held(a) == [@name]
      assert html =~ @rb
    end

    @tag timeout: 120_000
    test "#{surface}: control, a page posting the old number digest, no other save: written",
         c do
      c = Map.put(c, :surface, unquote(surface))
      put_rows(c, row("one two"))
      a = open(c)

      send_post(a, @name, %{
        "doc[meta].label" => "l0",
        "doc[meta].rows[0]._type" => "row",
        "doc[meta].rows[0]._key" => "r1",
        @name => "<p>ONE two</p>",
        "_bp_rt_owner" => legacy_owners(a, "one two")
      })

      assert eventually(fn -> row_words(c) == ["ONE two"] end)
    end
  end

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    @tag timeout: 120_000
    test "#{surface} #{how}: B's colliding row edit taken, A types on the first draw: B kept or merged",
         c do
      c = Map.put(c, :surface, unquote(surface))
      put_rows(c, row(@a_text))
      a = open(c)
      put_rows(c, row(@b_text))
      assert eventually(fn -> words(hd(form(a)["meta"]["rows"])["rt"]) == [@b_text] end)

      html = a_posts(a, unquote(how), "<p>#{@a_text} A</p>")
      kept = row_words(c)

      # On main: ["row text 1120 A"], B's 8568 lost with no hold.
      assert kept == ["#{@b_text} A"] or
               (kept == [@b_text] and held(a) == [@name] and html =~ @rb),
             "B's row edit lost with no hold: #{inspect(kept)}"
    end
  end
end
