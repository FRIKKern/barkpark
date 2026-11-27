defmodule BarkparkWeb.Studio.PickInflightDrawingTest do
  @moduledoc """
  task-b7d86444f258c7aa (#29133 review, N2 and N1). A pick this socket
  wrote from the page's own post is kept with the widget drawing it was made
  on (`KeptPicks`): a pick back to the drawn value counts only on that
  drawing.

  N2: B saves Y, and A's widget is drawn again (`-g1`, drawn Y). A's pick X,
  made on the old drawing, lands after that. The record took the socket's
  drawing after the post (g1), so X read as picked on the drawing the page
  shows now. A's next key posts the redrawn Y as drawn, and Y was written
  over A's own X, with no banner. Each widget now posts the drawing it was
  drawn on (`_bp_drawn_at`, inside its ignored wrapper), and the record
  takes that.

  N1, stated as accepted: after a rejoin, the new socket has no record. A
  first post that picks back to the drawn value reads the same as a page
  that stayed on the old value while B saved (#29065 W1), so it is dropped,
  and the widget is drawn again from the store: A sees the value they
  picked away from, not a silent loss, and a pick of it again is written.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  @old_img %{"asset" => %{"_ref" => "image-old", "_type" => "reference"}, "_type" => "image"}

  setup %{conn: conn} do
    c = setup_doc(conn)
    {:ok, schema} = Content.get_schema(c.type, "production")

    fields =
      schema.fields ++
        [
          %{
            "name" => "reviewer",
            "title" => "Reviewer",
            "type" => "reference",
            "refType" => c.type
          },
          %{"name" => "cover", "title" => "Cover", "type" => "image"}
        ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => c.type, "title" => "Picks", "visibility" => "public", "fields" => fields},
        "production"
      )

    put_field(c, "reviewer", ref(c.id <> "-old"))
    put_field(c, "cover", @old_img)
    c
  end

  defp ref(id), do: %{"_ref" => id, "_type" => "reference"}
  defp h(text), do: "<p>#{text}</p>"

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

  defp doc_path(c, :desk), do: "#{c.root}/_desk/#{c.type};#{c.id}"
  defp doc_path(c, :studio), do: "#{c.root}/#{c.type}/#{c.id}"
  defp list_path(c, :desk), do: "#{c.root}/_desk/#{c.type}"
  defp list_path(c, :studio), do: "#{c.root}/#{c.type}"

  # A socket that rejoined: LiveViewTest joins with `_mounts: 0`, so the
  # rejoin's flags are set before the document's patch reads them.
  defp rejoined(c, surface) do
    {:ok, view, _} = live(c.conn, list_path(c, surface))
    flags = %{editor_rejoined?: true}
    flags = if surface == :desk, do: Map.put(flags, :desk_rejoin?, true), else: flags

    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns, &Map.merge(&1, flags))
    end)

    render_patch(view, doc_path(c, surface))
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp tab(c, surface) do
    {:ok, view, _html} = live(c.conn, doc_path(c, surface))
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp unescape(v), do: v |> String.replace("&quot;", ~s(")) |> String.replace("&amp;", "&")

  defp input_value(html, id) do
    case Regex.run(~r/<input[^>]*id="#{Regex.escape(id)}"[^>]*value="([^"]*)"/, html,
           capture: :all_but_first
         ) do
      [v] -> unescape(v)
      _ -> nil
    end
  end

  # What the page's widgets post: each hidden input, and the value each was
  # drawn with where the page draws one.
  defp page_picks(view) do
    html = render(view)

    %{
      doc: %{
        "reviewer" => input_value(html, "bp-ref-hidden-reviewer"),
        "cover" => input_value(html, "bp-mp-hidden-cover")
      },
      drawn: hidden(html, "_bp_drawn"),
      at: hidden(html, "_bp_drawn_at")
    }
  end

  # Each widget's `prefix[name]` hidden input, where the page draws one.
  defp hidden(html, prefix) do
    for name <- ~w(reviewer cover),
        [v] <- [
          Regex.run(~r/<input[^>]*name="#{prefix}\[#{name}\]"[^>]*value="([^"]*)"/, html,
            capture: :all_but_first
          )
        ],
        into: %{},
        do: {name, unescape(v)}
  end

  defp marks(params, picks) do
    params
    |> then(&if(picks.drawn == %{}, do: &1, else: Map.put(&1, "_bp_drawn", picks.drawn)))
    |> then(&if(picks.at == %{}, do: &1, else: Map.put(&1, "_bp_drawn_at", picks.at)))
  end

  defp post(view, target, doc, picks) do
    params = marks(%{"_target" => target, "doc" => Map.merge(%{"title" => "T0"}, doc)}, picks)
    view |> element("#editor-form") |> render_change(params)
  end

  defp body_key(view, text, picks),
    do: post(view, ["doc[body]"], Map.merge(picks.doc, %{"body" => h(text)}), picks)

  defp wrap(view, prefix) do
    [id] = Regex.run(~r/id="(#{prefix}-[^"]+)"/, render(view), capture: :all_but_first)
    id
  end

  defp reviewer(c), do: stored(c)["reviewer"]

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} N2: A's pick from the old drawing lands after B's redraw; A's next key keeps it",
         c do
      a = tab(c, @surface)
      picks0 = page_picks(a)
      {x, y} = {c.id <> "-x", c.id <> "-y"}
      w0 = wrap(a, "bp-ref-wrap-reviewer")

      put_field(c, "reviewer", ref(y))
      assert eventually(fn -> page_picks(a).drawn["reviewer"] == y end)

      refute wrap(a, "bp-ref-wrap-reviewer") == w0,
             "B's save did not draw the widget again: no test"

      # A's pick, made on the old drawing, lands after the redraw.
      post(a, ["doc[reviewer]"], %{picks0.doc | "reviewer" => x}, picks0)
      assert eventually(fn -> reviewer(c)["_ref"] == x end)

      # The page shows the redrawn widget (Y, drawn Y) and posts it with a key.
      now = page_picks(a)
      assert now.drawn["reviewer"] == y
      body_key(a, "body0 N2", now)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 N2"] end)

      # On main: the redrawn Y was written over A's own X.
      assert reviewer(c)["_ref"] == x, "the redrawn Y was written over A's own pick X"
      assert page_picks(a).drawn["reviewer"] == x, "the widget was not drawn again from the store"
    end

    test "#{surface} N2 forged: a redrawn post naming the pick's old drawing is still dropped",
         c do
      a = tab(c, @surface)
      picks0 = page_picks(a)
      assert picks0.at["reviewer"] not in [nil, ""], "the widget posts no drawing: no test"
      {x, y} = {c.id <> "-x", c.id <> "-y"}

      put_field(c, "reviewer", ref(y))
      assert eventually(fn -> page_picks(a).drawn["reviewer"] == y end)
      post(a, ["doc[reviewer]"], %{picks0.doc | "reviewer" => x}, picks0)
      assert eventually(fn -> reviewer(c)["_ref"] == x end)

      # The redrawn widget posts Y as drawn, but names the drawing A's pick
      # was kept for: a posted drawing never makes a post A's pick back.
      now = page_picks(a)
      assert now.drawn["reviewer"] == y
      body_key(a, "body0 N2f", %{now | at: picks0.at})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 N2f"] end)
      assert reviewer(c)["_ref"] == x, "a forged _bp_drawn_at wrote the redrawn Y over A's X"
    end

    test "#{surface} P1: a pick back on the drawing the pick was made on is written", c do
      a = tab(c, @surface)
      picks = page_picks(a)
      old = c.id <> "-old"
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => c.id <> "-x"}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-x" end)
      body_key(a, "body0 P1", %{picks | doc: %{picks.doc | "reviewer" => old}})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 P1"] end)
      assert reviewer(c)["_ref"] == old, "the pick back was dropped"
    end

    test "#{surface} P1 from a page with no _bp_drawn_at (drawn before this deploy): written",
         c do
      a = tab(c, @surface)
      picks = %{page_picks(a) | at: %{}}
      old = c.id <> "-old"
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => c.id <> "-x"}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-x" end)
      body_key(a, "body0 P1", %{picks | doc: %{picks.doc | "reviewer" => old}})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 P1"] end)
      assert reviewer(c)["_ref"] == old
    end

    test "#{surface} N1 (accepted): after a rejoin a first post picking back is dropped, shown, and a pick again is written",
         c do
      a = tab(c, @surface)
      picks = page_picks(a)
      {old, x} = {c.id <> "-old", c.id <> "-x"}
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => x}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == x end)
      GenServer.stop(a.pid, :normal)

      # The rejoined page kept its ignored widget: it shows old, drawn old.
      a2 = rejoined(c, @surface)
      back = %{picks | doc: %{picks.doc | "reviewer" => old}}
      body_key(a2, "body0 N1", back)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 N1"] end)
      assert reviewer(c)["_ref"] == x
      # Not silent: the widget is drawn again from the store.
      assert page_picks(a2).drawn["reviewer"] == x

      post(a2, ["doc[reviewer]"], %{page_picks(a2).doc | "reviewer" => old}, page_picks(a2))
      assert eventually(fn -> reviewer(c)["_ref"] == old end)
    end
  end
end
