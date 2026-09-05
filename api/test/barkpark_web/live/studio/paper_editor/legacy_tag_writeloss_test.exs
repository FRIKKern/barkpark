defmodule BarkparkWeb.Studio.PaperEditor.LegacyTagWritelossTest do
  @moduledoc """
  D37 (authoring-excellence W4) — the PaperFieldBlock composite editor must NOT
  discard a legacy flat-string tag row on its first subfield edit.

  Historically the `tags` field persisted each row as a bare STRING
  (`["obsidian"]`) rather than the current
  `%{"tag" => …, "strength" => …, "rationale" => …}` map. Two seams conspired to
  drop the name on the first edit:

    1. RENDER — the composite editor read `get_value("obsidian", "tag", "") == ""`,
       so a legacy row rendered with a BLANK `tag` input. A `phx-change`
       serialises the WHOLE form, so the first edit re-submitted an empty
       `[i].tag` and the name was lost. `derive_value/1` now reconstitutes a
       legacy bare-string composite row as `%{"tag" => s}` before it reaches the
       editor, so the name renders in its field and rides the next change intact.
    2. MERGE — `put_path_in/3` lands a subfield edit via
       `Map.put(ensure_map(child), key, value)`; the old `ensure_map/1`
       (`is_map` + `_ -> %{}`) turned a bare string into `%{}`. A new
       `is_binary` head preserves the scalar under `"tag"` as belt-and-suspenders.

  The `"tag"` subfield key is double-proven for the field that carries this
  legacy form: the paper schema's tags composite ({"name":"tag"}) AND the
  label_spine validator (reads `get(top, "tag")`).

  The reconstitution is GENERIC across arrayOf-of-composite fields but gated on
  the element type (scalar arrays keep their bare strings), so the second test
  pins the blast radius: a non-tag composite's map elements round-trip unharmed,
  and a bare scalar is PRESERVED rather than dropped — strictly safer than the
  old `%{}`, and inert in practice because `tags` is the sole composite that ever
  persisted a bare-string form.

  Fixtures are section-local; the shared base paper + `open_editor` come from
  `BarkparkWeb.PaperEditorTestHelpers`.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  # A tags-shaped arrayOf-of-composite block (mirrors priv/plugins/bulldocs/
  # schemas/paper.json tags `of`: tag / strength / rationale). Element 0 is a
  # LEGACY bare string; element 1 is the current map shape.
  @tags_slug "2026-07-13-legacy-tag-paper"

  defp seed_legacy_tags_paper! do
    blocks = [
      %{
        "id" => "c-tags",
        "type" => "arrayOf",
        "label" => "Tags",
        "ordered" => false,
        "of" => %{
          "name" => "tag_entry",
          "type" => "composite",
          "fields" => [
            %{"name" => "tag", "title" => "Tag", "type" => "string"},
            %{"name" => "strength", "title" => "Strength", "type" => "number"},
            %{"name" => "rationale", "title" => "Rationale", "type" => "string"}
          ]
        },
        # Element 0: legacy bare string. Element 1: current map shape.
        "value" => [
          "obsidian",
          %{"tag" => "search", "strength" => 40, "rationale" => "findability"}
        ]
      }
    ]

    # bypass_wall (charter D26 audit): an editor-mechanics fixture, not a wall
    # test. The publish wall (integrated from ae-upsert-paper-wall) would 422 a
    # tagless paper birth; bypassing keeps the seeded blocks PRISTINE so the
    # render/round-trip assertions below see exactly the legacy shape under test.
    {:ok, paper} =
      Content.upsert_paper(%{slug: @tags_slug, dataset: @dataset, blocks: blocks},
        bypass_wall: true
      )

    paper
  end

  test "a legacy bare-string tag row keeps its name when a subfield is first edited",
       %{conn: conn} do
    seed_legacy_tags_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@tags_slug}"))

    edit_html = open_editor(view)

    # RENDER seam: the legacy scalar is reconstituted, so its `tag` input carries
    # the name (not the blank the pre-fix render produced).
    assert edit_html =~ ~s(value="obsidian")

    pid_before = view.pid

    # Edit element 0's `strength`. A form phx-change serialises the WHOLE form:
    # element 0 now contributes `[0].tag="obsidian"` (populated by the render
    # fix) alongside my `[0].strength="80"`. PRE-FIX the row rendered a blank tag,
    # so this would persist `tag=""` and LOSE "obsidian"; this asserts the name
    # survives.
    flush_form(view, ~s([data-block-id="c-tags"] form), %{"[0].strength" => "80"})

    render(view)

    block =
      Content.paper_blocks(@tags_slug, @dataset) |> Enum.find(&(&1["id"] == "c-tags"))

    assert block["type"] == "arrayOf"

    row0 = Enum.at(block["value"], 0)
    # THE invariant: the legacy tag name survived the first subfield edit. Reds on
    # the pre-fix behavior (row0["tag"] == "").
    assert row0["tag"] == "obsidian"
    # The edit itself landed.
    assert row0["strength"] == "80"

    # The already-map sibling row kept its tag name (it, too, rides the full-form
    # serialization; numeric strength is re-serialized as a string, which is the
    # editor's pre-existing behavior, not this fix's concern).
    row1 = Enum.at(block["value"], 1)
    assert row1["tag"] == "search"
    assert row1["rationale"] == "findability"

    # No remount — the op rode the canonical delta path.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  # GENERICITY GUARD (crit 2): a NON-tag composite (amount / currency — declares
  # NO `tag` subfield). The reconstitution is scoped to tag-declaring composites,
  # so this field must NEVER acquire a spurious `tag` key.
  @nontag_slug "2026-07-13-nontag-composite-paper"

  defp seed_nontag_composite_paper! do
    blocks = [
      %{
        "id" => "c-prices",
        "type" => "arrayOf",
        "label" => "Prices",
        "ordered" => true,
        "of" => %{
          "name" => "price",
          "type" => "composite",
          "fields" => [
            %{"name" => "amount", "title" => "Amount", "type" => "string"},
            %{"name" => "currency", "title" => "Currency", "type" => "string"}
          ]
        },
        "value" => [
          %{"amount" => "299", "currency" => "USD"},
          %{"amount" => "150", "currency" => "NOK"}
        ]
      }
    ]

    # bypass_wall (charter D26 audit): editor-mechanics fixture — see the tags
    # seed above for the rationale.
    {:ok, paper} =
      Content.upsert_paper(%{slug: @nontag_slug, dataset: @dataset, blocks: blocks},
        bypass_wall: true
      )

    paper
  end

  test "a non-tag composite never gets a spurious tag key — reconstitution is scoped to the tags path",
       %{conn: conn} do
    seed_nontag_composite_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@nontag_slug}"))

    open_editor(view)

    flush_form(view, ~s([data-block-id="c-prices"] form), %{"[1].currency" => "SEK"})

    render(view)

    block =
      Content.paper_blocks(@nontag_slug, @dataset) |> Enum.find(&(&1["id"] == "c-prices"))

    # The edited element round-tripped: only `currency` changed, `amount` survived.
    row1 = Enum.at(block["value"], 1)
    assert row1["amount"] == "150"
    assert row1["currency"] == "SEK"

    # NO element of this non-tag composite acquired a spurious "tag" key — the
    # blanket is_binary reconstitution never touches a composite that does not
    # declare a `tag` subfield.
    for row <- block["value"] do
      refute Map.has_key?(row, "tag")
    end
  end

  # A SCALAR arrayOf (of.type == "string") legitimately holds bare strings; the
  # reconstitution must never fire for it (of.type gate), or every keyword would
  # be mangled into a `%{"tag" => …}` map.
  @scalar_slug "2026-07-13-scalar-array-paper"

  defp seed_scalar_array_paper! do
    blocks = [
      %{
        "id" => "c-keywords",
        "type" => "arrayOf",
        "label" => "Keywords",
        "ordered" => true,
        "of" => %{"name" => "keyword", "type" => "string"},
        "value" => ["history", "norway"]
      }
    ]

    # bypass_wall (charter D26 audit): editor-mechanics fixture — see the tags
    # seed above for the rationale.
    {:ok, paper} =
      Content.upsert_paper(%{slug: @scalar_slug, dataset: @dataset, blocks: blocks},
        bypass_wall: true
      )

    paper
  end

  test "a scalar arrayOf keeps its bare strings — reconstitution never fires for a non-composite element",
       %{conn: conn} do
    seed_scalar_array_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@scalar_slug}"))

    open_editor(view)

    flush_form(view, ~s([data-block-id="c-keywords"] form), %{"[1]" => "sweden"})

    render(view)

    block =
      Content.paper_blocks(@scalar_slug, @dataset) |> Enum.find(&(&1["id"] == "c-keywords"))

    # Bare strings stayed bare — no element was turned into a %{"tag" => …} map.
    assert block["value"] == ["history", "sweden"]
  end

  defp flush_form(view, selector, values) do
    target = element(view, selector)
    render_change(target, values)

    render_hook(target, "inner-flush", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev,
      "values" => values
    })
  end
end
