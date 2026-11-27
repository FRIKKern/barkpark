defmodule BarkparkWeb.Studio.RepickAfterRedrawTest do
  @moduledoc """
  task-36b1558c058a5f3b (#29085 review, D3 and D4). A picks X, B saves Y,
  and the widget is drawn again as Y. A picks X again and, inside the
  widget's 500 ms debounce, types in the body or presses Save, so the post
  does not target the reference. Studio writes the re-pick (#29085 r2). The
  desk dropped it, and showed Y: a deliberate pick was lost.

  BRK2 stays: a body key from a page that had not drawn Y yet (it posts X
  as drawn) keeps B's Y. So does H1: B saves back the value A's page still
  draws, and A's post of X comes from the old drawing.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias BarkparkWeb.Components.FieldInputs

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

  # The socket's form value of `field`, as the store's B saved.
  defp form_value(a, field), do: :sys.get_state(a.pid).socket.assigns.editor_form[field]

  # H1 (#29146 r1 review): A picks X; B saves back the value A's page still
  # draws (an undo of A's pick). A's socket takes it, and the redraw has not
  # reached the page: its post of X (drawn old, on the old drawing) is A's
  # stale pick, not a pick on the redrawn widget. The desk keeps B's undo.
  # The Studio too (task-2e3d79fc1480d2db).
  defp undone_before_redraw(c, a, field, x, old, old_form?) do
    picks = page_picks(a)
    post(a, ["doc[#{field}]"], %{picks.doc | field => x.post}, picks)
    assert eventually(fn -> x.stored.(stored(c)) end)
    put_field(c, field, old)

    assert eventually(fn -> old_form?.(form_value(a, field)) end),
           "B's undo was not taken: no test"

    %{picks | doc: %{picks.doc | field => x.post}}
  end

  defp old_ref?(c), do: &(FieldInputs.reference_id(&1) == c.id <> "-old")
  defp old_img?(v), do: FieldInputs.image_form_value(v) =~ "image-old"

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{@surface} H1: B undoes A's pick before the redraw; A's body key posts X: B's undo kept",
         c do
      a = tab(c, @surface)
      {x, _y} = ref_case(c)
      stale = undone_before_redraw(c, a, "reviewer", x, ref(c.id <> "-old"), old_ref?(c))
      body_key(a, "body0 H1", stale)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 H1"] end)
      assert reviewer(c)["_ref"] == c.id <> "-old", "A's stale X was written over B's undo"
    end

    test "#{@surface} H1i: the same for an image: B's undo kept", c do
      a = tab(c, @surface)
      {x, _y} = img_case()
      stale = undone_before_redraw(c, a, "cover", x, @old_img, &old_img?/1)
      body_key(a, "body0 H1i", stale)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 H1i"] end)

      assert cover(c)["asset"]["_ref"] == "image-old",
             "A's stale image X was written over B's undo"
    end

    test "#{@surface} H1s: B undoes A's pick before the redraw; A presses Save: B's undo kept",
         c do
      a = tab(c, @surface)
      {x, _y} = ref_case(c)
      stale = undone_before_redraw(c, a, "reviewer", x, ref(c.id <> "-old"), old_ref?(c))
      save(a, stale)

      assert reviewer(c)["_ref"] == c.id <> "-old",
             "A's stale X was written over B's undo on Save"
    end
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
