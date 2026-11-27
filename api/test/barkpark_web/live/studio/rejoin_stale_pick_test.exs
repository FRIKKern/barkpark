defmodule BarkparkWeb.Studio.RejoinStalePickTest do
  @moduledoc """
  task-e2c23aefdf44fad4 (#29065 review W0/W1): a reference or image widget
  is drawn once (`phx-update="ignore"`) and its hidden input keeps the value
  it was drawn with. B saved a new reference while A's socket was down; A's
  rejoined page posts its whole form with the next key in another field, and
  that stale value read as A's edit against the rejoin's fresh load: B's
  reference was written over, with no banner.

  The widget posts the value it was drawn with (`_bp_drawn`). A pick posted
  as drawn, in a post that is not a change of that field, is not the page's
  edit (`KeptPicks`): the store keeps B's, and the widget is drawn again from
  the store.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content

  @moduletag :studio_live

  @old_img %{"asset" => %{"_ref" => "image-old", "_type" => "reference"}, "_type" => "image"}
  @new_img %{"asset" => %{"_ref" => "image-new", "_type" => "reference"}, "_type" => "image"}

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
  defp cover(c), do: stored(c)["cover"]

  # A's page, drawn with the old picks; its socket drops, B saves new ones,
  # and A's page rejoins a new socket with its stale widgets.
  defp away_while_b_picks(c, surface) do
    a = tab(c, surface)
    picks = page_picks(a)
    assert picks.doc["reviewer"] == c.id <> "-old"
    GenServer.stop(a.pid, :normal)
    put_field(c, "reviewer", ref(c.id <> "-new"))
    put_field(c, "cover", @new_img)
    {rejoined(c, surface), picks}
  end

  for surface <- [:desk, :studio] do
    @surface surface

    test "#{surface} rejoin: a key in the body keeps B's reference and image", c do
      {a2, picks} = away_while_b_picks(c, @surface)
      body_key(a2, "body0 A7", picks)
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 A7"] end)
      assert reviewer(c)["_ref"] == c.id <> "-new", "A's stale reference was written over B's"
      assert cover(c)["asset"]["_ref"] == "image-new", "A's stale image was written over B's"
    end

    test "#{surface} rejoin: after the key, the widgets are drawn from the store", c do
      {a2, picks} = away_while_b_picks(c, @surface)
      before = {wrap(a2, "bp-ref-wrap-reviewer"), wrap(a2, "bp-mp-wrap-cover")}
      body_wrap = wrap(a2, "bp-rt-wrap-body")
      body_key(a2, "body0 A7", picks)
      now = page_picks(a2)

      # A widget is drawn once (`phx-update="ignore"`): only a new wrapper id
      # draws it again on the page. The body A types in is not drawn again.
      {ref_wrap, img_wrap} = before

      refute wrap(a2, "bp-ref-wrap-reviewer") == ref_wrap,
             "the reference widget was not drawn again"

      refute wrap(a2, "bp-mp-wrap-cover") == img_wrap, "the image widget was not drawn again"
      assert wrap(a2, "bp-rt-wrap-body") == body_wrap, "the body A types in was drawn again"
      assert now.doc["reviewer"] == c.id <> "-new"
      assert now.drawn["reviewer"] == c.id <> "-new"
      assert now.doc["cover"] =~ "image-new"
      assert now.drawn["cover"] =~ "image-new"

      # A picks the old reference back: that is A's change, and it is written.
      post(a2, ["doc[reviewer]"], %{"reviewer" => c.id <> "-old"}, now)
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-old" end)
    end

    test "#{surface} rejoin: a Save keeps B's reference and image", c do
      {a2, picks} = away_while_b_picks(c, @surface)
      body_key(a2, "body0 A7", picks)
      save(a2, %{picks | doc: Map.put(picks.doc, "body", h("body0 A7"))})
      assert reviewer(c)["_ref"] == c.id <> "-new"
      assert cover(c)["asset"]["_ref"] == "image-new"
    end

    # #29075 r1 review: the page's own pick is not drawn again, so its
    # `_bp_drawn` stays the first value; a pick back to it is A's.
    test "#{surface} control: a pick back to the drawn value, on a key in the body, is written",
         c do
      a = tab(c, @surface)
      picks = page_picks(a)
      old = c.id <> "-old"
      ref_wrap = wrap(a, "bp-ref-wrap-reviewer")
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => c.id <> "-x"}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-x" end)
      assert wrap(a, "bp-ref-wrap-reviewer") == ref_wrap
      body_key(a, "body0 P1", %{picks | doc: %{picks.doc | "reviewer" => old}})
      assert eventually(fn -> words(stored(c)["body"]) == ["body0 P1"] end)
      assert reviewer(c)["_ref"] == old, "A's pick back to the drawn value was dropped"
    end

    test "#{surface} control: a pick back to the drawn value, then Save, is written", c do
      a = tab(c, @surface)
      picks = page_picks(a)
      old = c.id <> "-old"
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => c.id <> "-x"}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-x" end)
      save(a, %{picks | doc: %{picks.doc | "reviewer" => old}})
      assert reviewer(c)["_ref"] == old, "A's pick back to the drawn value was dropped"
    end

    test "#{surface} control: an empty reference picked and cleared again, then Save, is cleared",
         c do
      put_field(c, "reviewer", nil)
      a = tab(c, @surface)
      picks = page_picks(a)
      assert picks.drawn["reviewer"] == ""
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => c.id <> "-x"}, picks)
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-x" end)
      save(a, %{picks | doc: %{picks.doc | "reviewer" => ""}})
      assert reviewer(c) in [nil, ""], "A's clear was dropped"
    end

    test "#{surface} control: a pick posted with a key in another field is written", c do
      a = tab(c, @surface)
      picks = page_picks(a)
      # The pick's own debounced change is cancelled by the body key, so the
      # body's post is the only one that carries it.
      doc = %{picks.doc | "reviewer" => c.id <> "-picked"}
      body_key(a, "body0 A1", %{picks | doc: doc})
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-picked" end)
    end

    test "#{surface} control: a cleared reference is written", c do
      a = tab(c, @surface)
      picks = page_picks(a)
      post(a, ["doc[reviewer]"], %{picks.doc | "reviewer" => ""}, picks)
      assert eventually(fn -> reviewer(c) in [nil, ""] end)
    end

    test "#{surface} control: a cleared reference posted with a key in another field is written",
         c do
      a = tab(c, @surface)
      picks = page_picks(a)
      body_key(a, "body0 A1", %{picks | doc: %{picks.doc | "reviewer" => ""}})
      assert eventually(fn -> reviewer(c) in [nil, ""] end)
    end

    test "#{surface} control: a Save with a fresh pick writes it", c do
      a = tab(c, @surface)
      picks = page_picks(a)
      save(a, %{picks | doc: %{picks.doc | "reviewer" => c.id <> "-saved"}})
      assert eventually(fn -> reviewer(c)["_ref"] == c.id <> "-saved" end)
    end
  end
end
