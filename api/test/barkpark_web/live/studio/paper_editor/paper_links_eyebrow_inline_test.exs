defmodule BarkparkWeb.Studio.PaperEditor.PaperLinksEyebrowInlineTest do
  # A chapters/timeline paper-links card paints each reference's authored eyebrow
  # ("02 Aug") above its title. In Edit the eyebrow sat in the card's open-paper
  # link, so clicking it navigated to the linked paper instead of editing it. It now
  # edits in place through the same guarded reference-copy form as title/description.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render.Compose
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "an authored eyebrow edits in place in the reader's own box" do
    for layout <- ["timeline", "chapters"] do
      block = paper_links(layout, [ref(%{"eyebrow" => "02 Aug"})])
      tree = block |> render_fields() |> LazyHTML.from_fragment()

      owner = LazyHTML.query(tree, ".bp-paper-link-ref-eyebrow-owner")
      assert Enum.count(owner) == 1, layout

      reader_card = reader_card(block)

      assert LazyHTML.attribute(owner, "style") == [reader_card.eyebrow_style],
             "#{layout}: Edit paints the eyebrow with the reader span's exact style"

      paint = LazyHTML.query(owner, "[data-paper-link-ref-eyebrow-paint]")
      assert LazyHTML.text(paint) == "02 Aug"

      form = LazyHTML.query(owner, ~s(form[data-test-id="paper-link-ref-eyebrow-editor"]))

      assert LazyHTML.attribute(LazyHTML.query(form, ~s([name="paper-link-ref-field"])), "value") ==
               ["eyebrow"]

      assert LazyHTML.text(LazyHTML.query(form, "textarea")) == "02 Aug"

      [dom_id] = LazyHTML.attribute(LazyHTML.query(form, "textarea"), "id")
      assert LazyHTML.attribute(paint, "aria-controls") == [dom_id]

      refute LazyHTML.to_html(tree) =~ ~s(>02 Aug</span>),
             "#{layout}: the eyebrow is not painted a second time as raw reader markup"
    end
  end

  test "a timeline's generated default eyebrow stays plain text with a form to author one" do
    block = paper_links("timeline", [ref(%{})])
    tree = block |> render_fields() |> LazyHTML.from_fragment()
    owner = LazyHTML.query(tree, ".bp-paper-link-ref-eyebrow-owner")

    assert LazyHTML.attribute(owner, "data-paper-link-ref-eyebrow-default") == ["true"]
    assert Enum.count(LazyHTML.query(owner, "[data-paper-link-ref-eyebrow-paint]")) == 0

    assert LazyHTML.text(LazyHTML.query(owner, ".bp-paper-link-ref-eyebrow-paint-wrapper")) =~
             "Edition"

    assert LazyHTML.attribute(LazyHTML.query(owner, "textarea"), "tabindex") == ["-1"]
  end

  test "a chapters card without an eyebrow paints none" do
    tree = paper_links("chapters", [ref(%{})]) |> render_fields() |> LazyHTML.from_fragment()
    assert Enum.count(LazyHTML.query(tree, ".bp-paper-link-ref-eyebrow-owner")) == 0
  end

  test "an eyebrow save changes only that reference's eyebrow; the guard ignores the eyebrow" do
    first = ref(%{"eyebrow" => "02 Aug", "meta" => "74 changes"})
    sibling = %{"slug" => "sibling", "eyebrow" => "06 Aug"}
    block = paper_links("timeline", [first, sibling])

    assert Blocks.paper_link_ref_guard(Map.put(first, "eyebrow", "03 Aug")) ===
             Blocks.paper_link_ref_guard(first)

    assert {:ok,
            %{"op" => "patch-block", "id" => "links", "patch" => %{"refs" => [updated, ^sibling]}}} =
             Blocks.resolve_block_form([block], source(first, "eyebrow", "03 Aug"))

    assert updated === Map.put(first, "eyebrow", "03 Aug")

    assert {:ok, %{"patch" => %{"refs" => [cleared, ^sibling]}}} =
             Blocks.resolve_block_form([block], source(first, "eyebrow", "  "))

    assert cleared === Map.delete(first, "eyebrow")

    # Only title, description and eyebrow are reference copy.
    assert {:error, {:source_validation, _}} =
             Blocks.resolve_block_form([block], source(first, "meta", "75 changes"))
  end

  defp render_fields(block),
    do: render_component(&PaperEditor.paper_block_fields/1, %{block: block, paper_links: %{}})

  defp reader_card(block) do
    [card] =
      block
      |> Map.put("_paper_links", %{})
      |> Compose.paper_links_presentation(:article)
      |> Map.fetch!(:cards)

    card
  end

  defp paper_links(layout, refs),
    do: %{"id" => "links", "type" => "paper-links", "layout" => layout, "refs" => refs}

  defp ref(extra) do
    Map.merge(
      %{
        "slug" => "target",
        "title" => "The cause stays visible",
        "prefer_authored_copy" => true,
        "unknown" => %{"keep" => true}
      },
      extra
    )
  end

  defp source(ref, field, value) do
    %{
      "block_id" => "links",
      "paper-link-ref-index" => "0",
      "paper-link-ref-slug" => "target",
      "paper-link-ref-field" => field,
      "paper-link-ref-value" => value,
      "paper-link-ref-guard" => Blocks.paper_link_ref_guard(ref)
    }
  end
end
