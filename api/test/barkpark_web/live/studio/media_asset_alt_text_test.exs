defmodule BarkparkWeb.Studio.MediaAssetAltTextTest do
  @moduledoc """
  S9 crit 3, altText half (task-6d80c6cc7d97b1d1).

  The row's premise: "altText is already settable via `bp media update` and
  already lives on the asset schema — the gap is that the Studio UI never
  exposes it, so an editor sets alt text in the asset panel without touching
  the API."

  What the investigation actually found, and what these tests pin:

    * `altText` IS on the `mediaAsset` schema (`priv/plugins/media/schemas/
      media_asset.json`) as a `localizedText` field, and the Studio editor
      ALREADY has a renderer for `localizedText`
      (`BarkparkWeb.Components.Fields.LocalizedTextField`). Nothing needs
      writing.
    * The reason an editor still cannot set alt text is a ROUTING hole:
      `PaneBuilder.resolve/4`'s ungated-fallback arm returns the RAW nav_path
      alongside the ungated tree. `mediaAsset` is not a ROOT item of that tree
      — `Barkpark.Structure` nests it under the `media-desk` node — so the walk
      finds no child named `mediaAsset`, drops the editor to `nil`, and
      `/studio/mediaAsset/<id>` renders the "Studio could not open this
      document" card. The `#1851` never-unreachable guarantee that arm exists
      to uphold does not hold for the one type that only lives off the top menu.

  So this is a WIRING job exactly as the row predicted — the wire that was
  missing is the path normalization, not an input.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PaneBuilder

  @dataset "production"

  # The REAL production schema, read from the media plugin's own priv file.
  # Inventing a fixture schema here would let this test pass against a shape
  # production does not have — `altText` is a `localizedText` field in the
  # `metadata` GROUP, and the group is why it sits behind a tab.
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
    raw = "s9-alt-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Barkpark.Auth.create_token(raw, "s9-alt", @dataset, ["read", "write", "admin"])

    {build_conn() |> Plug.Test.init_test_session(%{"api_token" => raw}), raw}
  end

  setup do
    seed_media_asset_schema!()
    slug = "s9-alt-asset-#{System.unique_integer([:positive])}"
    seed_asset_doc!(slug)
    {:ok, slug: slug}
  end

  # ── RED-before layer 1: the resolution seam ────────────────────────────────
  test "a mediaAsset nav path resolves to a document editor", %{slug: slug} do
    {panes, editor} = PaneBuilder.build(@dataset, ["mediaAsset", slug])

    opened? = is_map(editor) and Map.get(editor, :type) == "mediaAsset"

    assert opened?,
           "PaneBuilder dropped the mediaAsset editor to #{inspect(editor)}; " <>
             "panes were #{inspect(Enum.map(panes, & &1[:title]))}"
  end

  # ── RED-before layer 2: the rendered surface ───────────────────────────────
  test "the asset panel renders an editable Alt text input", %{slug: slug} do
    {conn, _raw} = editor_conn!()

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{slug}"))

    unresolved? = html =~ "studio-unresolved-document-notice"
    refute unresolved?, "the editor rendered the 'could not open' card instead of the asset"

    # `altText` sits in the schema's `metadata` group, so the panel opens on
    # the `file` tab. Selecting Metadata is what an editor does; it is a tab
    # switch, not an API call.
    metadata = render_click(view, "select-group", %{"group" => "metadata"})

    has_alt_field? = metadata =~ ~s(data-field-name="altText")
    assert has_alt_field?, "no altText field rendered in the asset panel"

    # The localizedText renderer must give an actual INPUT per language, not a
    # read-only echo — an editor has to be able to type here.
    has_alt_input? =
      metadata =~ ~s(name="doc[altText].nob") and metadata =~ ~s(name="doc[altText].eng")
    assert has_alt_input?, "altText rendered without a writable per-language input"
  end

  # ── The round trip the row's ACCEPTANCE names: set alt text in the panel,
  #    read it back off the document, WITHOUT touching the API. ──────────────
  test "an editor sets alt text in the panel and it persists on the document", %{slug: slug} do
    {conn, _raw} = editor_conn!()

    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{slug}"))

    render_click(view, "select-group", %{"group" => "metadata"})

    # THE WIRE SHAPE, stated exactly. `LocalizedTextField` emits
    # `name="doc[altText].nob"`; LiveView's form serializer sends that string
    # and Phoenix decodes it with `Plug.Conn.Query`, which yields the nested
    # map below. This is the payload `Fields.save/2` receives.
    decoded = Plug.Conn.Query.decode("doc[altText].nob=Et+fyrt%C3%A5rn+i+t%C3%A5ke")
    IO.inspect(decoded, label: "DECODED")

    render_submit(view, "save", %{
      "doc" => %{
        "altText" => %{"nob" => "Et fyrtårn i tåke", "eng" => "A lighthouse in fog"}
      }
    })

    # Draft-first: the editor's save writes the draft, exactly as it does for
    # every other type. Either row proves the round trip persisted.
    doc =
      case Content.get_document("drafts.#{slug}", "mediaAsset", @dataset) do
        {:ok, d} -> d
        _ -> case Content.get_document(slug, "mediaAsset", @dataset) do
               {:ok, d} -> d
               _ -> nil
             end
      end

    alt = doc && get_in(doc.content, ["altText"])
    stored? = is_map(alt) and Map.get(alt, "nob") == "Et fyrtårn i tåke"

    assert stored?, "alt text did not persist; content was #{inspect(doc && doc.content)}"
  end

  # ── The permission side: an anonymous visitor gets no editable panel. ──────
  test "an anonymous visitor gets no editable alt-text input", %{slug: slug} do
    result = live(build_conn(), scoped_studio("/d/#{@dataset}/studio/mediaAsset/#{slug}"))

    denied? =
      case result do
        {:error, _} ->
          true

        {:ok, _view, html} ->
          not (html =~ ~s(<form id="editor-form"))
      end

    assert denied?, "an anonymous mount rendered a writable editor form for a mediaAsset"
  end
end
