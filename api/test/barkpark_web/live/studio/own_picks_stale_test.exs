defmodule BarkparkWeb.Studio.OwnPicksStaleTest do
  @moduledoc """
  task-030e09c0bde818b1 (#29075 r2 review, BRK1, BRK1b, BRK3). A pick this
  socket wrote from the page's own post (`editor_own_picks`, `KeptPicks`)
  is the page's: a pick back to the value the widget was drawn with is
  written. The record outlived the widget it was made for:

  - it survived a remote replace, which draws the widget again from the
    store (BRK1);
  - it took every posted value the form held, also one the page never
    picked: a key in the body recorded the drawn value (BRK1b);
  - it survived a trip to the list and back, which loads the document
    again (BRK3, studio).

  Then B saved back the recorded value, and A's post from the redrawn
  widget read as A's own pick: B's value was written over, with no banner.

  A record now holds only a pick (a posted value that is not the drawn
  one), for the widget drawing it was made on (the form generation and the
  widget's own), and a document load drops it. A pick back to the drawn
  value is still written (P1, P2).
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

    drawn =
      for name <- ~w(reviewer cover),
          [v] <-
            [
              Regex.run(~r/<input[^>]*name="_bp_drawn\[#{name}\]"[^>]*value="([^"]*)"/, html,
                capture: :all_but_first
              )
            ],
          into: %{},
          do: {name, unescape(v)}

    %{
      doc: %{
        "reviewer" => input_value(html, "bp-ref-hidden-reviewer"),
        "cover" => input_value(html, "bp-mp-hidden-cover")
      },
      drawn: drawn
    }
  end

  defp post(view, target, doc, picks) do
    params = %{"_target" => target, "doc" => Map.merge(%{"title" => "T0"}, doc)}
    params = if picks.drawn == %{}, do: params, else: Map.put(params, "_bp_drawn", picks.drawn)
    view |> element("#editor-form") |> render_change(params)
  end

  defp body_key(view, text, picks),
    do: post(view, ["doc[body]"], Map.merge(picks.doc, %{"body" => h(text)}), picks)

  defp save(view, picks) do
    params = %{"doc" => Map.merge(%{"title" => "T0"}, picks.doc)}
    params = if picks.drawn == %{}, do: params, else: Map.put(params, "_bp_drawn", picks.drawn)
    view |> element("#editor-form") |> render_submit(params)
  end

  defp wrap(view, prefix) do
    [id] = Regex.run(~r/id="(#{prefix}-[^"]+)"/, render(view), capture: :all_but_first)
    id
  end

  defp reviewer(c), do: stored(c)["reviewer"]

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} P1: pick X, then pick back the drawn value on a body key: written", c do
      a = tab(c, @surface)
      picks = page_picks(a)
      old = c.id <> "-old"
      w0 = wrap(a, "bp-ref-wrap-reviewer")
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => c.id <> "-x"}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-x" end)
      # Not drawn again after the page's own pick: `_bp_drawn` stays old.
      assert wrap(a, "bp-ref-wrap-reviewer") == w0
      body_key(a, "body0 P1", %{picks | doc: %{picks.doc | "reviewer" => old}})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 P1"] end)
      assert reviewer(c)["_ref"] == old, "the pick back was dropped: #{inspect(reviewer(c))}"
    end

    test "#{surface} P2: pick X, then pick back the drawn value and Save: written", c do
      a = tab(c, @surface)
      picks = page_picks(a)
      old = c.id <> "-old"
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => c.id <> "-x"}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-x" end)
      save(a, %{picks | doc: %{picks.doc | "reviewer" => old}})
      assert reviewer(c)["_ref"] == old, "the Save of the pick back was dropped"
    end

    test "#{surface} P1 then B saves X: A's next key, posting the drawn value, keeps B's X", c do
      a = tab(c, @surface)
      picks = page_picks(a)
      old = c.id <> "-old"
      x = c.id <> "-x"
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => x}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == x end)
      back = %{picks | doc: %{picks.doc | "reviewer" => old}}
      body_key(a, "body0 P1", back)
      assert eventually(fn -> reviewer(c)["_ref"] == old end)

      # B's save reaches A's socket; A's page, not yet drawn again, posts
      # old as drawn with the next key.
      put_field(c, "reviewer", ref(x))
      body_key(a, "body0 P1 more", back)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 P1 more"] end)
      assert reviewer(c)["_ref"] == x, "A's drawn old was written over B's X"
    end

    test "#{surface} BRK1: own pick X; B saves Y (A drawn again); B saves X; A's post of Y keeps X",
         c do
      a = tab(c, @surface)
      picks = page_picks(a)
      x = c.id <> "-x"
      y = c.id <> "-y"
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => x}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == x end)
      put_field(c, "reviewer", ref(y))
      assert eventually(fn -> page_picks(a).drawn["reviewer"] == y end)
      at_y = page_picks(a)
      put_field(c, "reviewer", ref(x))
      body_key(a, "body0 B1", at_y)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 B1"] end)
      # On main: A's stale Y was written over B's X.
      assert reviewer(c)["_ref"] == x,
             "A's stale Y was written over B's X: #{inspect(reviewer(c))}"
    end

    test "#{surface} BRK1b: no pick; A types; B saves Y (A drawn again); B saves O; A's post of Y keeps O",
         c do
      a = tab(c, @surface)
      picks = page_picks(a)
      old = c.id <> "-old"
      y = c.id <> "-y"
      body_key(a, "body0 B0", picks)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 B0"] end)
      put_field(c, "reviewer", ref(y))
      assert eventually(fn -> page_picks(a).drawn["reviewer"] == y end)
      at_y = page_picks(a)
      put_field(c, "reviewer", ref(old))
      body_key(a, "body0 B1b", at_y)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 B1b"] end)

      assert reviewer(c)["_ref"] == old,
             "A's stale Y was written over B's O: #{inspect(reviewer(c))}"
    end

    test "#{surface} BRK3: own pick X; to the list and back (drawn Y); B saves X; A's post of Y keeps X",
         c do
      a = tab(c, @surface)
      picks = page_picks(a)
      x = c.id <> "-x"
      y = c.id <> "-y"
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => x}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == x end)
      render_patch(a, list_path(c, @surface))
      put_field(c, "reviewer", ref(y))
      render_patch(a, doc_path(c, @surface))
      render_async(a, 5_000)

      assert eventually(fn ->
               has_element?(a, "#editor-form") and page_picks(a).drawn["reviewer"] == y
             end)

      at_y = page_picks(a)
      put_field(c, "reviewer", ref(x))
      body_key(a, "body0 B3", at_y)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 B3"] end)

      assert reviewer(c)["_ref"] == x,
             "A's stale Y was written over B's X: #{inspect(reviewer(c))}"
    end
  end
end
