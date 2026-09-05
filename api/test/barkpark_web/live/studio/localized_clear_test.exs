defmodule BarkparkWeb.Studio.LocalizedClearTest do
  @moduledoc """
  task-bf3c7b7af0071f0d — clearing a localizedText value back to empty.

  PR #16066 folded the flat dotted form keys (`doc[altText].nob`, which
  `Plug.Conn.Query.decode/1` leaves at the TOP level because the name does not
  end in `]`) back into the `"doc"` map, but SKIPPED every empty value: a
  composite field renders each subfield on every render, so a task form posts
  `doc[purpose].importance.score=""` plus eighteen empty siblings, and folding
  those in submitted empty strings into typed slots.

  The cost, stated in that PR: an author who CLEARS a localized value sees the
  OLD value survive the save. These tests pin both halves of the distinction:

    1. a value the author cleared persists as cleared (the fold now admits an
       empty value for a path named by `phx-change`'s `_target`), and
    2. an empty dotted key the renderer posted WITHOUT the author touching it
       is still ignored — the guard that keeps the composite saves green.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  # The REAL production schema, from the media plugin's own priv file, for the
  # same reason the sibling alt-text test reads it: `altText` must be a
  # `localizedText` field in the `metadata` group or this test proves nothing
  # about the shape production renders.
  defp seed_media_asset_schema! do
    attrs =
      Path.join([:code.priv_dir(:barkpark), "plugins", "media", "schemas", "media_asset.json"])
      |> File.read!()
      |> Jason.decode!()

    {:ok, _} = Content.upsert_schema(attrs, @dataset)
    :ok
  end

  defp seed_asset_doc!(slug) do
    {:ok, doc} =
      Content.upsert_document(
        "mediaAsset",
        %{
          "doc_id" => slug,
          "title" => "Cover photo",
          "status" => "published",
          "content" => %{}
        },
        @dataset,
        source: :api
      )

    doc
  end

  defp editor_conn! do
    raw = "loc-clear-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(raw, "loc-clear", @dataset, ["read", "write", "admin"])

    build_conn() |> Plug.Test.init_test_session(%{"api_token" => raw})
  end

  # Read the alt-text map back off whichever row the editor wrote (draft-first,
  # exactly as the sibling test does).
  defp stored_alt_text(slug) do
    doc =
      case Content.get_document("drafts.#{slug}", "mediaAsset", @dataset) do
        {:ok, d} ->
          d

        _ ->
          case Content.get_document(slug, "mediaAsset", @dataset) do
            {:ok, d} -> d
            _ -> nil
          end
      end

    doc && get_in(doc.content, ["altText"])
  end

  # THE WIRE SHAPE, never a hand-nested map: `LocalizedTextField` emits
  # `name="doc[altText].nob"`, LiveView serializes the form to a query string
  # and Phoenix decodes it with `Plug.Conn.Query`, which does NOT nest the
  # trailing dot segment.
  defp wire(query), do: Plug.Conn.Query.decode(query)

  @filled "doc[title]=Cover+photo&doc[altText].nob=Et+fyrt%C3%A5rn+i+t%C3%A5ke" <>
            "&doc[altText].eng=A+lighthouse+in+fog"

  @cleared "doc[title]=Cover+photo&doc[altText].nob=&doc[altText].eng="

  setup do
    seed_media_asset_schema!()
    slug = "loc-clear-asset-#{System.unique_integer([:positive])}"
    seed_asset_doc!(slug)
    {:ok, slug: slug}
  end

  defp open_metadata_panel!(slug) do
    {:ok, view, html} =
      live(editor_conn!(), scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{slug}"))

    unresolved? = html =~ "studio-unresolved-document-notice"
    refute unresolved?, "the editor rendered the 'could not open' card instead of the asset"

    render_click(view, "select-group", %{"group" => "metadata"})
    view
  end

  # ── RED-before on main: the clear is dropped and the old value survives ────
  test "clearing a localized value back to empty persists as cleared", %{slug: slug} do
    view = open_metadata_panel!(slug)

    # 1. The author types alt text and saves it. This half already works
    #    (#16066) and is the fixture the clear needs.
    render_submit(view, "save", wire(@filled))

    set = stored_alt_text(slug)
    set? = is_map(set) and Map.get(set, "nob") == "Et fyrtårn i tåke"

    assert set?,
           "precondition failed — alt text never persisted in the first place; stored: " <>
             inspect(set)

    # 2. The author now selects the text in each language box and deletes it.
    #    Each keystroke fires the form's `phx-change`, and LiveView names the
    #    input that fired it in `_target` — for a dotted field name that is the
    #    verbatim params key (`Plug.Conn.Query.decode/1` leaves a name that does
    #    not end in `]` whole, and `decode_merge_target/1` wraps it in a list).
    render_change(view, "autosave", Map.put(wire(@cleared), "_target", ["doc[altText].nob"]))
    render_change(view, "autosave", Map.put(wire(@cleared), "_target", ["doc[altText].eng"]))

    # 3. …and hits Save. A `phx-submit` carries NO `_target`, which is exactly
    #    why the touched set has to outlive the change events above.
    render_submit(view, "save", wire(@cleared))

    cleared = stored_alt_text(slug)
    nob = if is_map(cleared), do: Map.get(cleared, "nob"), else: nil
    cleared? = nob in [nil, ""]

    assert cleared?,
           "the cleared alt text did not persist; the old value survived the save. stored: " <>
             inspect(cleared)
  end

  # ── The guard that keeps the composite saves green ─────────────────────────
  #
  # A composite/array renderer posts every subfield on every render, touched or
  # not. An empty dotted key whose input the author never touched must STILL be
  # dropped, or those empties land in typed slots and the write is refused.
  test "an empty dotted key the author never touched does not overwrite the stored value", %{
    slug: slug
  } do
    view = open_metadata_panel!(slug)

    render_submit(view, "save", wire(@filled))

    # The author edits an UNRELATED field. The renderer still posts the empty
    # `doc[altText]` inputs alongside it — that is the composite shape — but
    # `_target` names only the field that actually changed.
    untouched_empties =
      "doc[title]=Cover+photo&doc[altText].nob=&doc[altText].eng=&doc[credit].nob="

    render_change(
      view,
      "autosave",
      Map.put(wire(untouched_empties), "_target", ["doc", "title"])
    )

    render_submit(view, "save", wire(untouched_empties))

    survived = stored_alt_text(slug)
    survived? = is_map(survived) and Map.get(survived, "nob") == "Et fyrtårn i tåke"

    assert survived?,
           "an untouched empty subfield the renderer posted wiped a stored value; stored: " <>
             inspect(survived)
  end
end
