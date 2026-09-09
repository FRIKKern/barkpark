defmodule BarkparkWeb.Studio.PaperEditor.PaperLinksReferenceCopyPatchTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "admits one uniquely identified authored reference and returns its raw slug" do
    ref = authored_ref(%{"slug" => "  target  ", "title" => "Before"})

    assert {:ok, %{slug: "  target  ", guard: guard}} =
             Blocks.paper_link_reference_copy_admission(paper_links([ref]), 0)

    assert is_binary(guard)
    assert guard == Blocks.paper_link_ref_guard(ref)

    assert {:error, :paper_link_reference_copy_unavailable} =
             Blocks.paper_link_reference_copy_admission(
               paper_links([
                 ref,
                 "target",
                 %{"slug" => " target ", "prefer_authored_copy" => false}
               ]),
               0
             )
  end

  test "updates one authored reference field from authoritative source without refolding carriers" do
    first = authored_ref(%{"title" => "Before", "description" => "Before description"})
    sibling = %{"slug" => "sibling", "unknown" => [%{"keep" => true}]}
    block = paper_links([first, sibling])

    assert {:ok, %{"op" => "patch-block", "id" => "links", "patch" => %{"refs" => refs}}} =
             Blocks.resolve_block_form(
               [block],
               source(first, %{
                 "paper-link-ref-field" => "title",
                 "paper-link-ref-value" => "  Authored title  "
               })
             )

    assert [updated, ^sibling] = refs
    assert updated["title"] == "  Authored title  "
    assert updated["description"] == "Before description"
    assert updated["unknown"] === first["unknown"]
    assert Map.drop(updated, ["title"]) === Map.drop(first, ["title"])
    assert block === paper_links([first, sibling])
  end

  test "field admission rejects opaque selected values but permits opaque sibling copy" do
    for opaque <- [%{"keep" => true}, ["keep"], true, 1.5] do
      ref = authored_ref(%{"title" => opaque, "description" => "Safe"})
      block = paper_links([ref])

      assert {:ok, _row} = Blocks.paper_link_reference_copy_admission(block, 0)

      assert {:error, :paper_link_reference_copy_unavailable} =
               Blocks.paper_link_reference_copy_admission(block, 0, "title")

      assert {:ok, _field} =
               Blocks.paper_link_reference_copy_admission(block, 0, "description")

      assert {:error, {:source_validation, :invalid_paper_link_reference_copy}} =
               Blocks.resolve_block_form(
                 [block],
                 source(ref, %{
                   "paper-link-ref-field" => "title",
                   "paper-link-ref-value" => "Overwrite"
                 })
               )
    end

    opaque_description = %{"keep" => [true, nil]}
    ref = authored_ref(%{"title" => "Before", "description" => opaque_description})

    assert {:ok, %{"patch" => %{"refs" => [updated]}}} =
             Blocks.resolve_block_form(
               [paper_links([ref])],
               source(ref, %{"paper-link-ref-value" => "After"})
             )

    assert updated["title"] == "After"
    assert updated["description"] === opaque_description
  end

  test "representable absent nil integer and exact string values submit as source-preserving no-ops" do
    cases = [
      {%{}, ""},
      {%{"title" => nil}, ""},
      {%{"title" => 42}, "42"},
      {%{"title" => "Before"}, "Before"},
      {%{"title" => "   "}, "   "}
    ]

    for {copy, submitted} <- cases do
      ref = authored_ref(copy)
      block = paper_links([ref])

      assert {:ok, _admission} =
               Blocks.paper_link_reference_copy_admission(block, 0, "title")

      assert {:ok, %{"patch" => %{}}} =
               Blocks.resolve_block_form(
                 [block],
                 source(ref, %{"paper-link-ref-value" => submitted})
               )

      assert block === paper_links([ref])
    end

    assert {:error, :paper_link_reference_copy_unavailable} =
             Blocks.paper_link_reference_copy_admission(
               paper_links([authored_ref(%{"title" => "Before"})]),
               0,
               "eyebrow"
             )
  end

  test "blank deletes only the selected field and exact no-op returns an empty patch" do
    first = authored_ref(%{"title" => "Before", "description" => "Keep"})
    block = paper_links([first])

    assert {:ok, %{"patch" => %{"refs" => [updated]}}} =
             Blocks.resolve_block_form(
               [block],
               source(first, %{
                 "paper-link-ref-field" => "title",
                 "paper-link-ref-value" => "  "
               })
             )

    refute Map.has_key?(updated, "title")
    assert Map.drop(updated, ["title"]) === Map.drop(first, ["title"])

    assert {:ok, %{"patch" => %{}}} =
             Blocks.resolve_block_form(
               [block],
               source(first, %{
                 "paper-link-ref-field" => "description",
                 "paper-link-ref-value" => "Keep"
               })
             )
  end

  test "one identity guard survives a queued title save before description resolves" do
    original = authored_ref(%{"title" => "Before", "description" => "Before description"})
    guard = Blocks.paper_link_ref_guard(original)
    after_title = put_in(original["title"], "After title")

    assert {:ok, %{"patch" => %{"refs" => [updated]}}} =
             Blocks.resolve_block_form([paper_links([after_title])], %{
               "block_id" => "links",
               "paper-link-ref-index" => "0",
               "paper-link-ref-slug" => "target",
               "paper-link-ref-field" => "description",
               "paper-link-ref-value" => "After description",
               "paper-link-ref-guard" => guard
             })

    assert updated["title"] == "After title"
    assert updated["description"] == "After description"
  end

  test "rejects malformed, stale, ambiguous, and overbroad scalar reference sources" do
    first = authored_ref(%{})
    base = source(first, %{})

    invalid = [
      {paper_links([first]), Map.put(base, "paper-link-ref-index", "00")},
      {paper_links([first]), Map.put(base, "paper-link-ref-index", "1")},
      {paper_links([first]), Map.put(base, "paper-link-ref-slug", "other")},
      {paper_links([first]), Map.put(base, "paper-link-ref-field", "eyebrow")},
      {paper_links([first]), Map.put(base, "paper-link-ref-value", 42)},
      {paper_links([first]), Map.put(base, "extra", "forged")},
      {paper_links([Map.put(first, "prefer_authored_copy", false)]), base},
      {paper_links(["target"]), base},
      {%{"id" => "links", "type" => "paper-links", "refs" => %{}}, base},
      {paper_links([first]), Map.put(base, "paper-link-ref-guard", "malformed")},
      {paper_links([Map.put(first, "unknown", "changed")]), base},
      {paper_links([first, first]), base},
      {paper_links([first, " target "]), base}
    ]

    for {block, params} <- invalid do
      assert {:error, {:source_validation, _reason}} =
               Blocks.resolve_block_form([block], params)
    end
  end

  defp paper_links(refs),
    do: %{
      "id" => "links",
      "type" => "paper-links",
      "layout" => "chapters",
      "refs" => refs,
      "unknown" => %{"keep" => true}
    }

  defp authored_ref(extra) do
    Map.merge(
      %{
        "slug" => "target",
        "prefer_authored_copy" => true,
        "unknown" => %{"keep" => [true, nil, 1, 1.0]}
      },
      extra
    )
  end

  defp source(ref, overrides) do
    Map.merge(
      %{
        "block_id" => "links",
        "paper-link-ref-index" => "0",
        "paper-link-ref-slug" => "target",
        "paper-link-ref-field" => "title",
        "paper-link-ref-value" => "After",
        "paper-link-ref-guard" => Blocks.paper_link_ref_guard(ref)
      },
      overrides
    )
  end
end
