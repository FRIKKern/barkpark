defmodule BarkparkWeb.Studio.RepickAfterRedrawTest do
  @moduledoc """
  task-36b1558c058a5f3b (#29085 review, D3 and D4). A picks X, B saves Y,
  and the widget is drawn again as Y. A picks X again and, inside the
  widget's 500 ms debounce, types in the body or presses Save, so the post
  does not target the reference. Studio writes the re-pick (#29085 r2). The
  desk dropped it, and showed Y: a deliberate pick was lost.

  BRK2 stays: a body key from a page that had not drawn Y yet (it posts X
  as drawn) keeps B's Y.
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

  defp save(view, picks) do
    params = marks(%{"doc" => Map.merge(%{"title" => "T0"}, picks.doc)}, picks)
    view |> element("#editor-form") |> render_submit(params)
  end

  defp reviewer(c), do: stored(c)["reviewer"]
  defp cover(c), do: stored(c)["cover"]

  defp img(r),
    do: Jason.encode!(%{"asset" => %{"_ref" => r, "_type" => "reference"}, "_type" => "image"})

  # A's own pick X written; B's Y saved and drawn on A's page.
  defp redrawn_over_own(c, a, field, x, y) do
    picks = page_picks(a)
    post(a, ["doc[#{field}]"], %{picks.doc | field => x.post}, picks)
    assert eventually(fn -> x.stored.(stored(c)) end)
    put_field(c, field, y.value)

    assert eventually(fn -> page_picks(a).drawn[field] == y.post end),
           "B's save was not drawn: no test"

    page_picks(a)
  end

  defp ref_case(c) do
    {x, y} = {c.id <> "-x", c.id <> "-y"}

    {%{post: x, stored: &(&1["reviewer"]["_ref"] == x)},
     %{post: y, value: ref(y), stored: &(&1["reviewer"]["_ref"] == y)}}
  end

  defp img_case do
    {%{post: img("image-x"), stored: &(&1["cover"]["asset"]["_ref"] == "image-x")},
     %{
       post: img("image-y"),
       value: %{"asset" => %{"_ref" => "image-y", "_type" => "reference"}, "_type" => "image"},
       stored: &(&1["cover"]["asset"]["_ref"] == "image-y")
     }}
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{@surface} D3: a re-pick of X after B's Y is drawn, riding a body key, is written",
         c do
      a = tab(c, @surface)
      {x, y} = ref_case(c)
      at_y = redrawn_over_own(c, a, "reviewer", x, y)
      body_key(a, "body0 D3", %{at_y | doc: %{at_y.doc | "reviewer" => x.post}})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 D3"] end)
      assert reviewer(c)["_ref"] == x.post, "A's re-pick of X after the redraw was dropped"
    end

    test "#{@surface} D4: a re-pick of X after B's Y is drawn, then Save, is written", c do
      a = tab(c, @surface)
      {x, y} = ref_case(c)
      at_y = redrawn_over_own(c, a, "reviewer", x, y)
      save(a, %{at_y | doc: %{at_y.doc | "reviewer" => x.post}})

      assert eventually(fn -> reviewer(c)["_ref"] == x.post end),
             "A's re-pick of X after the redraw, then Save, was dropped"
    end

    test "#{@surface} D3 image: a re-pick of image X after B's Y is drawn, on a body key, is written",
         c do
      a = tab(c, @surface)
      {x, y} = img_case()
      at_y = redrawn_over_own(c, a, "cover", x, y)
      body_key(a, "body0 D3i", %{at_y | doc: %{at_y.doc | "cover" => x.post}})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 D3i"] end)
      assert cover(c)["asset"]["_ref"] == "image-x", "A's re-pick of image X was dropped"
    end

    test "#{@surface} BRK2: a body key from the page before Y is drawn (posts X as drawn) keeps B's Y",
         c do
      a = tab(c, @surface)
      picks = page_picks(a)
      {x, y} = ref_case(c)
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => x.post}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == x.post end)
      put_field(c, "reviewer", y.value)
      body_key(a, "body0 B2", %{picks | doc: %{picks.doc | "reviewer" => x.post}})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 B2"] end)
      assert reviewer(c)["_ref"] == y.post, "A's stale X rode over B's Y"
    end
  end
end
