defmodule Barkpark.PortableDoc.Render.SectionHeadTest do
  @moduledoc """
  The RENDERER half of the section-boundary contract (space.section →
  `--bp-section-*`).

  The device itself is CSS — `.bp-paper-surface > #paper-body > h2` and its
  keyed-stream leg draw air + a rule + a gap above every top-level level-2
  heading, and the render rig asserts the resulting 92px on a photographed page.
  But that selector only reaches what the renderer emits, and it distinguishes a
  section head from a component's own title by POSITION and by the ABSENCE of a
  class. Neither is checked by any CSS gate: give the heading emitter a class, or
  wrap it, and every stylesheet census stays green while the boundary vanishes
  from the reader.

  So this pins the two markup facts the rule depends on:

    1. a level-2 heading block renders as a BARE `<h2>` — no class, no wrapper —
       so the direct-child selector matches it;
    2. a component that emits its own `<h2>` (a `card`) keeps it INSIDE the
       component's element, so the same selector cannot reach it. That decoy is
       the reason the device is not on the shared `.bp-paper-surface h2` element
       rule at all.

  The corpus is authored in BPML (`Barkpark.PortableDoc.Bpml`) and round-tripped
  before it is rendered, so the fixture is readable as the document it describes
  and cannot drift from the blocks it produces. The `card` decoy is JSON: BPML's
  kernel vocabulary has no `card` tag (nor `divider`), which is noted at its use.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Bpml, Render}

  # A paper's real section boundaries: level-2 headings following prose. Every
  # h2 in the six render-rig fixtures has this shape — not one is an h1/h2 stack.
  @sections """
  <h1 id="title">Eight Minutes</h1>
  <p id="lede">A paragraph before the first boundary.</p>
  <h2 id="s1">What the timestamps say</h2>
  <p id="p1">The first section's body.</p>
  <h2 id="s2">Reconstructing it from the repository</h2>
  <p id="p2">The second section's body.</p>
  <h3 id="sub">A sub-beat, not a boundary</h3>
  <p id="p3">Which keeps prose rhythm, not section rhythm.</p>
  """

  defp render(blocks) do
    blocks
    |> Enum.map(&Render.render_block(&1, %{style: :article}))
    |> Enum.join()
  end

  describe "the markup the section-head selector depends on" do
    test "the BPML section corpus round-trips, so the fixture cannot drift from its blocks" do
      assert {:ok, blocks} = Bpml.parse_blocks(@sections)
      assert {:ok, ^blocks} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()
    end

    test "a level-2 heading renders as a BARE <h2> — no class, no wrapper" do
      {:ok, blocks} = Bpml.parse_blocks(@sections)
      html = render(blocks)

      # Exactly the two boundaries the corpus declares, each an attribute-less
      # tag. `<h2 class=…>` or `<div><h2>` would leave every stylesheet gate
      # green and the reader's section heads flat, because
      # `> #paper-body > h2` (and its `> div:not([class]) > h2` leg) would no
      # longer match.
      assert Regex.scan(~r/<h2\b[^>]*>/, html) |> Enum.map(&hd/1) == ["<h2>", "<h2>"]

      assert html =~ "<h2>What the timestamps say</h2>"
      assert html =~ "<h2>Reconstructing it from the repository</h2>"
    end

    test "a level-3 heading is a sub-beat and is NOT a section head" do
      {:ok, blocks} = Bpml.parse_blocks(@sections)
      html = render(blocks)

      # h3 renders bare too, but the device is keyed on h2 alone: a subsection
      # inside an argument is not a boundary between arguments.
      assert html =~ "<h3>A sub-beat, not a boundary</h3>"
      refute html =~ "<h2>A sub-beat, not a boundary</h2>"
    end

    test "a component's own <h2> stays inside the component, out of the selector's reach" do
      # THE DECOY, and the reason the device is not on `.bp-paper-surface h2`.
      # This is the real one, lifted from the `portabledoc-showcase` fixture: a
      # `card`'s title slot holds a heading block at level 4, `heading_level/1`
      # clamps an out-of-range level to 2, and the card's title renders as a bare
      # `<h2>` — markup an element rule cannot tell from a section head. Nothing
      # is wrong with the card; the level-4 spelling is ordinary authoring. What
      # separates the two is only that this h2 is nested inside
      # `<div class="bp-card …">`, which no `> #paper-body > h2` leg reaches.
      #
      # Authored as JSON, not BPML: the kernel vocabulary has no `card` tag (nor
      # `divider`), so the shapes this device most has to be careful around are
      # exactly the ones BPML cannot express today.
      card = %{
        "id" => "c1",
        "type" => "card",
        "tone" => "info",
        "slots" => %{
          "title" => [%{"type" => "heading", "level" => 4, "text" => "Reader"}],
          "body" => [
            %{
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Article chrome, zero setup."}]
            }
          ]
        }
      }

      html = render([card])

      assert html =~ ~r/<div class="bp-card[^"]*">\s*<h2>Reader<\/h2>/,
             """
             the card's title is no longer a bare <h2> inside .bp-card:

             #{html}

             This decoy is what the scoped selector exists for. If a component ever
             emits its title as a TOP-LEVEL bare <h2>, the section-head rule will draw
             a 92px boundary and a 2px ink rule above a card title — and no stylesheet
             gate would see it.
             """
    end
  end
end
