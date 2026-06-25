defmodule BarkparkWeb.Studio.PaperEditor.FieldBlocksTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR — field-* blocks (leaf, picker, reference VIEW).

    * P2.1 — field-* LEAF blocks: each renders a native control mounted with the
      BarkparkFieldBlockBridge hook; a paper-op patch-block persists the value.
    * P2.2 — field-reference / field-image PICKER blocks: the bp-reference-picker
      and bp-media-picker WCs mount inside the SAME bridge wrapper; a paper-op
      patch-block persists the chosen ref doc id / image URL.
    * Polish-1 (barkpark-nkoy) — field-reference VIEW mode resolves the
      referenced doc's TITLE (not the raw id) through the Content → Render spine,
      falling back to the stored id when no match exists.

  All three share the `@field_slug` paper (`seed_field_paper!`) — that fixture
  + the reference-VIEW fixtures (`seed_author!`, `seed_ref_view_paper!`) are
  section-local and stay here. The shared base paper + `open_editor` come from
  `BarkparkWeb.PaperEditorTestHelpers`.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  # ── field-* LEAF blocks (P2.1) ─────────────────────────────────────────────

  @field_slug "2026-05-24-fields-paper"

  defp seed_field_paper! do
    blocks = [
      %{"id" => "f-str", "type" => "field-string", "label" => "Name", "value" => "Knut"},
      %{"id" => "f-slug", "type" => "field-slug", "label" => "Slug", "value" => "knut"},
      %{"id" => "f-text", "type" => "field-text", "label" => "Bio", "value" => "Hi", "rows" => 4},
      %{"id" => "f-bool", "type" => "field-boolean", "label" => "Featured", "value" => false},
      %{
        "id" => "f-sel",
        "type" => "field-select",
        "label" => "Tone",
        "value" => "info",
        "options" => [
          %{"value" => "info", "label" => "Info"},
          %{"value" => "warning", "label" => "Warning"}
        ]
      },
      %{
        "id" => "f-dt",
        "type" => "field-datetime",
        "label" => "When",
        "value" => "2026-05-24T10:00"
      },
      %{"id" => "f-color", "type" => "field-color", "label" => "Accent", "value" => "#4f46e5"},
      %{
        "id" => "f-ref",
        "type" => "field-reference",
        "label" => "Author",
        "refType" => "author",
        "value" => "a1"
      },
      %{
        "id" => "f-img",
        "type" => "field-image",
        "label" => "Cover",
        "value" => ""
      }
    ]

    {:ok, paper} = Content.upsert_paper(%{slug: @field_slug, dataset: @dataset, blocks: blocks})
    paper
  end

  test "Edit mode renders a native control + BarkparkFieldBlockBridge for each field-* block",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    edit_html = open_editor(view)

    # Each field block gets a stable wrapper mounted with the bridge hook,
    # carrying its block id + field type for client-side coercion.
    for {id, type} <- [
          {"f-str", "field-string"},
          {"f-slug", "field-slug"},
          {"f-text", "field-text"},
          {"f-bool", "field-boolean"},
          {"f-sel", "field-select"},
          {"f-dt", "field-datetime"},
          {"f-color", "field-color"}
        ] do
      assert edit_html =~ ~s(id="paper-fld-#{id}")
      assert edit_html =~ ~s(data-block-id="#{id}")
      assert edit_html =~ ~s(data-field-type="#{type}")
    end

    assert edit_html =~ ~s(phx-hook="BarkparkFieldBlockBridge")
    # Native controls present with their seeded values.
    assert edit_html =~ ~s(data-test-id="paper-field-field-string")
    assert edit_html =~ ~s(<textarea)
    assert edit_html =~ ~s(type="checkbox")
    assert edit_html =~ ~s(type="datetime-local")
    assert edit_html =~ ~s(type="color")
    # The select renders the seeded option labels.
    assert edit_html =~ "Warning"
  end

  test "a paper-op patch-block on a field-string block persists the new value", %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-str",
      "patch" => %{"value" => "Solveig"}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-str"))
    assert block["type"] == "field-string"
    assert block["value"] == "Solveig"
    # label is untouched (shallow merge).
    assert block["label"] == "Name"
  end

  test "a paper-op patch-block on a field-boolean coerces + persists a real boolean",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    # The bridge sends a real JS boolean; assert the bool path. Also assert the
    # patch.ex coercion guard turns a stringy "true" into a real boolean.
    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-bool",
      "patch" => %{"value" => true}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-bool"))
    assert block["value"] === true

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-bool",
      "patch" => %{"value" => "false"}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-bool"))
    assert block["value"] === false
  end

  # ── field-reference / field-image PICKER blocks (P2.2) ─────────────────────

  test "Edit mode renders the bp-reference-picker + bp-media-picker picker WCs",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    edit_html = open_editor(view)

    # field-reference mounts a bp-reference-picker inside the standard bridge
    # wrapper, carrying its block id, field type, refType + dataset inline.
    assert edit_html =~ ~s(id="paper-fld-f-ref")
    assert edit_html =~ ~s(data-block-id="f-ref")
    assert edit_html =~ ~s(data-field-type="field-reference")
    assert edit_html =~ ~s(<bp-reference-picker)
    assert edit_html =~ ~s(ref-type="author")
    assert edit_html =~ ~s(data-test-id="paper-field-field-reference")

    # field-image mounts a bp-media-picker inside the same bridge wrapper.
    assert edit_html =~ ~s(id="paper-fld-f-img")
    assert edit_html =~ ~s(data-block-id="f-img")
    assert edit_html =~ ~s(data-field-type="field-image")
    assert edit_html =~ ~s(<bp-media-picker)
    assert edit_html =~ ~s(data-test-id="paper-field-field-image")

    # Both ride the SAME bridge hook the leaf fields use.
    assert edit_html =~ ~s(phx-hook="BarkparkFieldBlockBridge")
  end

  test "a paper-op patch-block on a field-reference persists the new ref doc id",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    # The bp-reference-picker emits a bubbling `bp-change` CustomEvent with
    # {detail:{value: <docId>}}; BarkparkFieldBlockBridge forwards detail.value
    # into a patch-block op pushed as `paper-op`. Simulate that wire — the op
    # arrives JSON-decoded with string keys, exactly as the handler accepts it.
    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-ref",
      "patch" => %{"value" => "a2"}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-ref"))
    assert block["type"] == "field-reference"
    assert block["value"] == "a2"
    # refType + label untouched (shallow merge).
    assert block["refType"] == "author"
    assert block["label"] == "Author"
  end

  test "a paper-op patch-block on a field-image persists the new image URL",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    # The bp-media-picker emits the same `bp-change` event carrying the image
    # URL string; the bridge forwards it as a patch-block op.
    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-img",
      "patch" => %{"value" => "/media/cover.png"}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-img"))
    assert block["type"] == "field-image"
    assert block["value"] == "/media/cover.png"
    assert block["label"] == "Cover"
  end

  # ── field-reference VIEW title resolution (Polish-1, barkpark-nkoy) ──────────
  #
  # View mode resolves the referenced doc's TITLE (not the raw id) through the
  # full Content → Render spine. The renderer stays pure; Content injects a
  # :ref_resolver bound to the dataset. A referable author doc must exist for
  # the title to resolve; with no match the row falls back to the stored id.

  @ref_view_slug "2026-05-24-ref-view-paper"

  defp seed_author!(doc_id, title) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_document("author", %{"doc_id" => doc_id, "title" => title}, @dataset)
  end

  defp seed_ref_view_paper!(value) do
    blocks = [
      %{
        "id" => "f-ref",
        "type" => "field-reference",
        "label" => "Author",
        "refType" => "author",
        "value" => value
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(%{slug: @ref_view_slug, dataset: @dataset, blocks: blocks})

    paper
  end

  test "View mode renders the referenced doc's TITLE, not the raw id", %{conn: conn} do
    seed_author!("ref-a1", "Solveig Aamodt")
    seed_ref_view_paper!("ref-a1")

    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@ref_view_slug}"))

    # The streamed read-only View shows the resolved title for the reference
    # row; the raw doc id never appears as the displayed value.
    assert html =~ "Solveig Aamodt"
    refute html =~ ">ref-a1<"
  end

  test "View mode falls back to the raw id when the referenced doc is absent",
       %{conn: conn} do
    # No author doc seeded for "ghost-ref" → reference_title returns the id.
    seed_ref_view_paper!("ghost-ref")

    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@ref_view_slug}"))

    assert html =~ "ghost-ref"
  end
end
