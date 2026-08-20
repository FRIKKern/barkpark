defmodule BarkparkWeb.Studio.WeightedLabelsTest do
  @moduledoc """
  ae-w10-studio-weighted-labels (authoring-excellence D76) — the Labels sidebar
  section renders the WEIGHT the publish wall enforces.

  Wave 1 made description + weighted registered tags a publish requirement;
  until this slice the Studio Labels section dropped strength, rationale and
  main_tag on the floor and rendered inert name chips. These tests pin the read
  side:

    1. ORDERING (mutation-proven): chips sort strength DESC with nil-strength
       (legacy flat) LAST. The fixture's INPUT order deliberately differs from
       the sorted order, so deleting the `Enum.sort_by` in
       `PaperCanvas.paper_label_entries/1` reds the assertion — red run
       documented in the task ledger.
    2. TOOLTIP: each weighted chip carries its rationale as a `title=`
       attribute; a chip without a rationale carries none.
    3. MAIN MARKER: the entry whose name equals `content["main_tag"]`
       (case-insensitive) is visually distinguished — exactly once.
    4. LEGACY GRACE: a flat string-tag doc renders names-only — no badges, no
       main marker, no crash.

  The spd containment census (`editor_panel_containment_test.exs`) runs in the
  same gate to prove this slice added no panel roots and touched no CSS.
  """
  use Barkpark.DataCase, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.{Components, PaperCanvas}

  @weighted_content %{
    # INPUT order is deliberately NOT the display order: mid-strength first,
    # a legacy flat string second, the main tag third, weakest last. Sorted
    # output must be alpha(90) > beta(40) > gamma(10) > legacy(nil).
    "tags" => [
      %{"tag" => "tag-beta", "strength" => 40, "rationale" => "supporting theme"},
      "tag-legacy",
      %{"tag" => "tag-alpha", "strength" => 90, "rationale" => "primary topic of the paper"},
      %{"tag" => "tag-gamma", "strength" => 10}
    ],
    "main_tag" => "Tag-Alpha"
  }

  defp sidebar(content) do
    render_component(&Components.paper_metadata_sidebar/1,
      paper_doc: %{
        content: content,
        status: "published",
        doc_id: "weighted-labels-fixture",
        title: "Weighted labels fixture"
      },
      dataset: "production"
    )
  end

  # Fixture names are chosen to appear EXACTLY once in the rendered document
  # (no attribute, icon or chrome carries them), so the first byte offset IS
  # the chip's position.
  defp chip_position(html, name) do
    case :binary.match(html, name) do
      {pos, _} -> pos
      :nomatch -> flunk("label chip #{inspect(name)} not rendered:\n#{html}")
    end
  end

  describe "strength ordering (mutation-proven)" do
    test "chips sort strength DESC with the legacy nil-strength chip LAST" do
      html = sidebar(@weighted_content)

      alpha = chip_position(html, "tag-alpha")
      beta = chip_position(html, "tag-beta")
      gamma = chip_position(html, "tag-gamma")
      legacy = chip_position(html, "tag-legacy")

      assert alpha < beta,
             "tag-alpha (90) must render before tag-beta (40) — strength sort missing"

      assert beta < gamma,
             "tag-beta (40) must render before tag-gamma (10) — strength sort missing"

      assert gamma < legacy,
             "legacy flat tag (nil strength) must render LAST, after tag-gamma (10)"
    end

    test "paper_label_entries/1 returns the sorted rich shape (unit pin)" do
      assert [
               %{
                 name: "tag-alpha",
                 strength: 90,
                 rationale: "primary topic of the paper",
                 main?: true
               },
               %{name: "tag-beta", strength: 40, rationale: "supporting theme", main?: false},
               %{name: "tag-gamma", strength: 10, rationale: nil, main?: false},
               %{name: "tag-legacy", strength: nil, rationale: nil, main?: false}
             ] = PaperCanvas.paper_label_entries(%{content: @weighted_content})
    end

    test "junk strength degrades to the legacy shape (sorts last) instead of raising" do
      entries =
        PaperCanvas.paper_label_entries(%{
          content: %{
            "tags" => [
              %{"tag" => "junk", "strength" => "ninety"},
              %{"tag" => "sane", "strength" => 5}
            ]
          }
        })

      assert [%{name: "sane", strength: 5}, %{name: "junk", strength: nil}] = entries
    end
  end

  describe "strength badges + rationale tooltips" do
    test "each weighted chip carries a numeric strength badge" do
      html = sidebar(@weighted_content)

      assert html =~ ~s(data-strength="90")
      assert html =~ ~s(data-strength="40")
      assert html =~ ~s(data-strength="10")
      # Three weighted chips ⇒ exactly three visible badges (legacy gets none).
      assert length(String.split(html, ~s(data-test-id="sidebar-label-strength"))) - 1 == 3
    end

    test "rationale renders as a title= tooltip; a chip without one carries no title" do
      html = sidebar(@weighted_content)

      assert html =~ ~s(title="primary topic of the paper")
      assert html =~ ~s(title="supporting theme")

      # tag-gamma has no rationale and tag-legacy is flat — neither may invent
      # a tooltip, so within the labels <ul> exactly two chips carry one
      # (bounded to the list: the Relations section has its own title= chrome).
      [_, rest] = String.split(html, ~s(data-test-id="sidebar-labels"), parts: 2)
      [labels_ul, _] = String.split(rest, "</ul>", parts: 2)
      assert length(String.split(labels_ul, "title=")) - 1 == 2
    end
  end

  describe "main-tag marker" do
    test "the main tag is marked exactly once, matched case-insensitively" do
      html = sidebar(@weighted_content)

      # main_tag "Tag-Alpha" matches entry "tag-alpha" despite the case gap.
      assert length(String.split(html, ~s(data-test-id="sidebar-label-main"))) - 1 == 1
      assert html =~ "<strong>tag-alpha</strong>"
      refute html =~ "<strong>tag-beta</strong>"
    end

    test "no main_tag key ⇒ no marker" do
      html = sidebar(Map.delete(@weighted_content, "main_tag"))

      refute html =~ ~s(data-test-id="sidebar-label-main")
      refute html =~ "<strong>tag-alpha</strong>"
    end
  end

  describe "legacy + empty states" do
    test "a legacy flat-tag doc renders names-only chips gracefully" do
      html = sidebar(%{"tags" => ["flat-one", "flat-two"]})

      assert chip_position(html, "flat-one") < chip_position(html, "flat-two")
      refute html =~ ~s(data-test-id="sidebar-label-strength")
      refute html =~ ~s(data-test-id="sidebar-label-main")
      refute html =~ "No labels yet."
    end

    test "a tagless paper keeps the honest empty state" do
      assert sidebar(%{}) =~ "No labels yet."
    end
  end
end
