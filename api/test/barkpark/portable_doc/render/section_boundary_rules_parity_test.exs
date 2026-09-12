defmodule Barkpark.PortableDoc.Render.SectionBoundaryRulesParityTest do
  @moduledoc """
  The Elixir leg of the ONE-RULE-PER-BOUNDARY parity lock (task-a4d1ae76fdb2a6b0).

  A `section` container used to open AND close on a full-width rule, so two
  adjacent sections stacked two hairlines where the grammar wants one. THIS
  engine settled the grammar in #16233 — `SectionLayout.stack_rules?/2` drops
  the pair for an untitled stack-mode section whose first child is a heading,
  because the heading already carries the boundary (paper-surface.css gives a
  container head the same beat/rule/gap a top-level `h2` gets, #15806). The Go
  TUI and the JS SDK kept drawing BOTH rules on the same published papers until
  the row that added this file.

  Three engines, ONE fixture file — `api/test/support/fixtures/section-boundary-rules.json`:

    Elixir  api/lib/barkpark/portable_doc/render/section_layout.ex  `stack_rules?/2`
            tested HERE
    Go      internal/pdrender/blocks.go                             `sectionStackRules`
            tested by internal/pdrender/section_boundary_rules_parity_test.go
    JS      js/packages/react/src/blocks/core.ts                    `sectionStackRules`
            tested by js/packages/react/tests/section-boundary-rules.parity.test.ts

  ONE file, not three generated mirrors — a mirror set drifts the moment one
  side is regenerated and the others are not, which is exactly the defect this
  row exists to close.

  DRIFT PROOF: make `stack_rules?/2` unconditionally `true` (the pre-#16233
  behaviour) and the three zero-rule cases red HERE while the Go and JS legs
  stay green.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  @article %{style: :article}

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "..",
             "support",
             "fixtures",
             "section-boundary-rules.json"
           ])
           |> Path.expand()

  setup_all do
    %{"cases" => cases} = @fixture |> File.read!() |> Jason.decode!()

    # Guard the fixture itself: a shrunken case list, or one that lost its
    # zero-rule arm, would make every assertion below vacuously pass.
    assert length(cases) >= 10
    assert Enum.count(cases, &(&1["rules"] == 0)) >= 3
    assert Enum.count(cases, &(&1["rules"] == 2)) >= 6

    {:ok, cases: cases}
  end

  # The number of BOUNDARY rules the section draws. Both legs of the reader emit
  # the same class — the stack leg adds an inline border-top-width, the grid leg
  # does not — so the class prefix counts both.
  defp rule_count(html), do: length(String.split(html, ~s(<hr class="bp-hr"))) - 1

  test "every fixture case draws exactly the rules it records", %{cases: cases} do
    for %{"name" => name, "block" => block, "rules" => want} <- cases do
      html = Render.render_blocks([block], @article)
      got = rule_count(html)

      assert got == want,
             "section boundary rules disagreed with the shared fixture for #{inspect(name)}: " <>
               "got #{got}, want #{want}\n#{html}"
    end
  end

  test "the suppressed shape really is the heading-opening one (the mutation control)", %{
    cases: cases
  } do
    # If `stack_rules?/2` were made unconditional the cases below would all draw
    # 2, so this asserts the discriminator is live rather than trusting the
    # per-case loop to have exercised both arms.
    zero = Enum.filter(cases, &(&1["rules"] == 0))

    for %{"block" => block} <- zero do
      assert is_nil(Map.get(block, "title")),
             "a zero-rule case must be UNTITLED — otherwise it is not testing the predicate"

      assert [%{"type" => "heading"} | _] = Map.get(block, "blocks")
      refute Render.render_blocks([block], @article) =~ ~s(<hr class="bp-hr")
    end
  end

  test "two adjacent heading-opening sections draw ONE boundary between them", %{cases: _} do
    section = fn text ->
      %{
        "type" => "section",
        "blocks" => [
          %{"type" => "heading", "level" => 2, "text" => text},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "body"}]}
        ]
      }
    end

    html = Render.render_blocks([section.("First"), section.("Second")], @article)

    # The whole point of the row: zero hairlines between the two sections. Each
    # boundary is the head's own border-top, drawn by paper-surface.css.
    assert rule_count(html) == 0
    assert html =~ ~s(<h2>First</h2>)
    assert html =~ ~s(<h2>Second</h2>)
  end
end
