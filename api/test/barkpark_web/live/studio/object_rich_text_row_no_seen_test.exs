defmodule BarkparkWeb.Studio.ObjectRichTextRowNoSeenTest do
  @moduledoc """
  task-82519fd79663e072: a rich text in an array row, posted by a page with
  no `_bp_rt_seen` (no bp-rt-remote.js), after B's save of that row was
  taken by A's socket. A's editor sits in a `phx-update="ignore"` wrapper
  keyed by the row's `_key`, so B's text never reached A's page: A typed on
  the row as first drawn. The row was written as posted, so B's words were
  lost with no banner (#28896 r2 review, N6).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  @name "doc[meta].rows[0].rt"
  @rb "Someone else rewrote"

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

  # The owner entries the page posts, as drawn.
  defp page_owners(view) do
    ~r/name="_bp_rt_owner\[\]" value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, v] -> String.replace(v, "&quot;", "\"") end)
  end

  # A's row post, typed on the row as A's page drew it.
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

  # A post sent before the page took a patch: exactly the fields given, not
  # merged with the page's patched inputs (`render_change` would).
  defp in_flight(a, how, fields) do
    %{editor_doc: d, dataset: ds} = :sys.get_state(a.pid).socket.assigns

    {owners, fields} = Map.pop(fields, "_bp_rt_owner")

    params =
      fields
      |> Map.merge(%{"doc[title]" => "T0"})
      |> URI.encode_query()
      |> Plug.Conn.Query.decode()
      |> Map.merge(%{
        "_bp_doc" => BarkparkWeb.Studio.StudioLive.PostIdentity.value(ds, d.type, d.doc_id),
        "_target" => [@name],
        "_bp_rt_owner" => owners
      })

    render_hook(a, if(how == :auto, do: "autosave", else: "save"), params)
  end

  # A opens the row at "one two"; B's save of it is taken by A's socket.
  defp b_taken(c, b_text) do
    put_rows(c, row("one two"))
    a = open(c)
    put_rows(c, row(b_text))
    assert eventually(fn -> words(hd(form(a)["meta"]["rows"])["rt"]) == [b_text] end)
    a
  end

  for surface <- [:desk, :studio], how <- [:auto, :save] do
    @tag timeout: 120_000
    test "#{surface} #{how}: B's row edit taken, A types another word: merged, or held",
         c do
      c = Map.put(c, :surface, unquote(surface))
      a = b_taken(c, "one twB")

      html = a_posts(a, unquote(how), "<p>ONE two</p>")
      kept = row_words(c)

      assert kept == ["ONE twB"] or (kept == ["one twB"] and held(a) == [@name] and html =~ @rb),
             "B's row edit lost with no hold: #{inspect(kept)}"
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: B's row edit taken, A types in the same word: held, B kept", c do
      c = Map.put(c, :surface, unquote(surface))
      a = b_taken(c, "one twoB")

      html = a_posts(a, unquote(how), "<p>one twoA</p>")

      assert row_words(c) == ["one twoB"]
      assert held(a) == [@name]
      assert html =~ @rb
    end

    # B takes out the row A is typing in; the next row moves up to its index
    # and A's page remounts there. A's post, typed on the row first drawn,
    # still names that row and its draw.
    @tag timeout: 120_000
    test "#{surface} #{how}: B deletes the row A types in: held or dropped, never in another row",
         c do
      c = Map.put(c, :surface, unquote(surface))
      r2 = %{"_type" => "row", "_key" => "r2", "rt" => [block("w2", "three four")]}
      put_rows(c, row("one two") ++ [r2])
      a = open(c)
      first_draw = page_owners(a)
      put_rows(c, [r2])
      assert eventually(fn -> length(form(a)["meta"]["rows"]) == 1 end)

      fields = %{
        "doc[meta].label" => "l0",
        "doc[meta].rows[0]._type" => "row",
        "doc[meta].rows[0]._key" => "r1",
        @name => "<p>ONE two</p>",
        "doc[meta].rows[1]._type" => "row",
        "doc[meta].rows[1]._key" => "r2",
        "doc[meta].rows[1].rt" => "<p>three four</p>",
        "_bp_rt_owner" => first_draw
      }

      in_flight(a, unquote(how), fields)

      rows = stored(c)["meta"]["rows"]
      by_key = Map.new(rows, &{&1["_key"], words(&1["rt"])})

      assert by_key["r2"] == ["three four"], "another row took A's words: #{inspect(rows)}"
      refute Enum.any?(rows, &(&1["_key"] != "r1" and words(&1["rt"]) == ["ONE two"]))

      assert held(a) != [] or not Map.has_key?(by_key, "r1"),
             "B's delete undone with no hold: #{inspect(by_key)}"
    end

    @tag timeout: 120_000
    test "#{surface} #{how}: control, no other save: A's row post is written", c do
      c = Map.put(c, :surface, unquote(surface))
      put_rows(c, row("one two"))
      a = open(c)

      html = a_posts(a, unquote(how), "<p>ONE two</p>")

      assert row_words(c) == ["ONE two"]
      refute html =~ @rb
    end
  end
end
