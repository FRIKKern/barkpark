defmodule BarkparkWeb.Studio.PaperEditor.PaperLinksMetaReasonInlineTest do
  # task-0b0790fbf00c236d. After the eyebrow slice, three kinds of authored
  # per-reference text a paper-links card paints were still not editable where
  # they read in Edit:
  #   - a chapters card's meta inside the generated footer "Live edition · <meta> →"
  #   - a default-layout card's reason after "Why it matters:"
  #   - every field of a card without prefer_authored_copy (the whole card rendered
  #     as the raw reader anchor, so a click opened the linked paper)
  # Each now edits in place through the guarded reference-copy form; the generated
  # footer label, the "Why it matters:" label and the live metadata stay text.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render.Compose
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "a chapters card's meta edits in place inside the generated footer" do
    block = paper_links("chapters", [ref(%{"meta" => "74 changes"})])
    tree = block |> render_fields(%{"target" => %{title: "Live"}}) |> LazyHTML.from_fragment()

    footer = LazyHTML.query(tree, ".bp-paper-link-ref-footer")
    assert Enum.count(footer) == 1

    assert LazyHTML.attribute(footer, "style") == [reader_card(block).footer_style],
           "Edit paints the footer with the reader span's exact style"

    assert LazyHTML.text(footer) =~ ~r/^\s*Live edition ·/
    assert LazyHTML.text(footer) =~ ~r/→\s*$/

    paint = LazyHTML.query(footer, "[data-paper-link-ref-meta-paint]")
    assert LazyHTML.text(paint) == "74 changes"

    form = LazyHTML.query(footer, ~s(form[data-test-id="paper-link-ref-meta-editor"]))

    assert LazyHTML.attribute(LazyHTML.query(form, ~s([name="paper-link-ref-field"])), "value") ==
             ["meta"]

    assert LazyHTML.text(LazyHTML.query(form, "textarea")) == "74 changes"
    [dom_id] = LazyHTML.attribute(LazyHTML.query(form, "textarea"), "id")
    assert LazyHTML.attribute(paint, "aria-controls") == [dom_id]
  end

  test "a chapters card without meta keeps its generated footer as plain text" do
    tree = paper_links("chapters", [ref(%{})]) |> render_fields() |> LazyHTML.from_fragment()
    assert Enum.count(LazyHTML.query(tree, ".bp-paper-link-ref-footer")) == 0
    assert Enum.count(LazyHTML.query(tree, "[data-paper-link-ref-meta-paint]")) == 0
    assert LazyHTML.to_html(tree) =~ "Edition"
  end

  test "a default card's own reason edits in place after the generated label" do
    block = paper_links(nil, [ref(%{"reason" => "It shows the census."})])
    tree = block |> render_fields() |> LazyHTML.from_fragment()

    owner = LazyHTML.query(tree, ".bp-paper-link-ref-reason-owner")
    assert Enum.count(owner) == 1
    assert LazyHTML.attribute(owner, "style") == [reader_card(block).reason_style]
    assert LazyHTML.text(LazyHTML.query(owner, "strong")) == "Why it matters:"

    paint = LazyHTML.query(owner, "[data-paper-link-ref-reason-paint]")
    assert LazyHTML.text(paint) == "It shows the census."

    form = LazyHTML.query(owner, ~s(form[data-test-id="paper-link-ref-reason-editor"]))
    assert LazyHTML.text(LazyHTML.query(form, "textarea")) == "It shows the census."
  end

  test "a reason from the block-level reasons map stays plain text" do
    block =
      paper_links(nil, [ref(%{})])
      |> Map.put("reasons", %{"target" => "Block-level reason."})

    tree = block |> render_fields() |> LazyHTML.from_fragment()
    owner = LazyHTML.query(tree, ".bp-paper-link-ref-reason-owner")
    assert LazyHTML.text(owner) =~ "Block-level reason."
    assert Enum.count(LazyHTML.query(owner, "[data-paper-link-ref-reason-paint]")) == 0
    assert Enum.count(LazyHTML.query(owner, "form")) == 0
  end

  test "a card without prefer_authored_copy edits its own copy; its live title/description stay the linked paper's" do
    live = %{"target" => %{title: "Live title", description: "Live description"}}

    block =
      paper_links("chapters", [
        %{
          "slug" => "target",
          "eyebrow" => "Week two",
          "meta" => "12 changes",
          "title" => "Fallback"
        }
      ])

    tree = block |> render_fields(live) |> LazyHTML.from_fragment()

    card = LazyHTML.query(tree, "[data-paper-link-card-editable]")
    assert Enum.count(card) == 1, "the card is the editable card, not the raw reader anchor"
    assert Enum.count(LazyHTML.query(tree, "a[data-paper-link-card]")) == 0

    assert LazyHTML.text(LazyHTML.query(card, "[data-paper-link-ref-eyebrow-paint]")) ==
             "Week two"

    assert LazyHTML.text(LazyHTML.query(card, "[data-paper-link-ref-meta-paint]")) == "12 changes"

    assert Enum.count(LazyHTML.query(card, "[data-paper-link-ref-title-paint]")) == 0
    assert Enum.count(LazyHTML.query(card, "[data-paper-link-ref-description-paint]")) == 0

    assert Enum.count(LazyHTML.query(card, ~s(form[data-test-id="paper-link-ref-title-editor"]))) ==
             0

    assert LazyHTML.text(LazyHTML.query(card, ".bp-paper-link-ref-title-owner")) =~ "Live title"

    assert LazyHTML.attribute(LazyHTML.query(card, "a[data-paper-link-open]"), "href") == [
             "/papers/target"
           ]
  end

  test "reader HTML for these cards is unchanged by the editor surface" do
    for layout <- ["chapters", nil] do
      block = paper_links(layout, [ref(%{"meta" => "74 changes", "reason" => "It shows."})])
      [card] = reader_card(block) |> List.wrap()
      refute card.html =~ "data-paper-link-ref"
      refute card.html =~ "<form"
    end
  end

  defp render_fields(block, live \\ %{}),
    do: render_component(&PaperEditor.paper_block_fields/1, %{block: block, paper_links: live})

  defp reader_card(block) do
    [card] =
      block
      |> Map.put("_paper_links", %{})
      |> Compose.paper_links_presentation(:article)
      |> Map.fetch!(:cards)

    card
  end

  defp paper_links(layout, refs) do
    %{"id" => "links", "type" => "paper-links", "refs" => refs}
    |> then(&if(layout, do: Map.put(&1, "layout", layout), else: &1))
  end

  defp ref(extra) do
    Map.merge(
      %{
        "slug" => "target",
        "title" => "The cause stays visible",
        "description" => "Authored description.",
        "prefer_authored_copy" => true,
        "unknown" => %{"keep" => true}
      },
      extra
    )
  end
end
