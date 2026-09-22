defmodule Barkpark.Content.Papers.ContainerDescentTest do
  @moduledoc """
  The write chokepoint's DESCENT — #11621.

  Before this change `normalize_render_block/1`, `block_element_errors/2` and
  `render_block_errors/2` each reduced over `["blocks", "children"]` and
  nothing else. A `steps` block keeps its body at `steps => [%{"blocks" => …}]`,
  TWO levels down; `tabs` the same; a `columns` entry IS a block list rather
  than a block. So nothing inside those three containers was normalized or
  error-walked by ANY arm — not the leaf pass, not the widget arm, not the
  wrapper recursion.

  All three walkers now descend through ONE owner
  (`BlockOps.reduce_child_block_lists/4`), which is what makes the "Descent"
  moduledoc's agreement sentence true rather than merely asserted. This file
  proves the agreement DIRECTLY: the same four placements are driven through
  all three walkers, and a placement that only one walker reached would red
  exactly one of the three blocks below.

  ## The control

  `@section_placement` is the `blocks` case — the ONE container that worked
  before this change. It is green on both sides of the change in every test
  here; if a run reds the control too, the fixture is wrong, not the descent.

  ## RED-BEFORE

  Against origin/main's `block_ops.ex`, 13 of these 21 tests fail — every
  steps/tabs/columns placement in all three walkers — and all four
  `@section_placement` controls pass.

  ## The nested_keys mutation

  #11621 proposed extending the recursion to `EpicQuality.nested_keys/0`.
  Replacing `reduce_child_block_lists/4` wholesale with a generic reduce over
  that set reds 7 of these tests, which is why the descent here is type-keyed
  instead:

    * `columns` is reached by NONE of the three walkers (4 tests) — a column
      is a LIST, so the generic reduce hands a list to the map-guarded
      normalizer clause, which returns it untouched.
    * an opaque `%{"columns" => ["not a block list"]}` body is COERCED rather
      than left alone.
    * a steps row carrying both `children` and `blocks` has the hidden
      `blocks` compatibility alias rewritten — the exact rewrite
      `PortableDoc.BlockIds` refuses by name.

  A `byline`'s string `items` DO survive that mutation, so this file does not
  claim otherwise; the byline test below is a regression pin, not a
  nested_keys discriminator.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.BlockOps

  # {label, wrap_fun, path of the wrapped child list}
  @section_placement {"blocks (control — reached before #11621)", &__MODULE__.wrap_section/1,
                      "blocks[0].blocks"}

  @placements [
    @section_placement,
    {"steps[].blocks", &__MODULE__.wrap_steps/1, "blocks[0].steps[0].blocks"},
    {"tabs[].blocks", &__MODULE__.wrap_tabs/1, "blocks[0].tabs[0].blocks"},
    {"columns[]", &__MODULE__.wrap_columns/1, "blocks[0].columns[0]"}
  ]

  def wrap_section(kids), do: %{"type" => "section", "id" => "c", "blocks" => kids}

  def wrap_steps(kids),
    do: %{"type" => "steps", "id" => "c", "steps" => [%{"title" => "One", "blocks" => kids}]}

  def wrap_tabs(kids),
    do: %{"type" => "tabs", "id" => "c", "tabs" => [%{"label" => "One", "blocks" => kids}]}

  def wrap_columns(kids), do: %{"type" => "columns", "id" => "c", "columns" => [kids]}

  # A `notes` block whose items are bare STRINGS — the live `heggemsnes-act`
  # shape, which renders empty rows until the widget arm rewrites it.
  defp notes_block, do: %{"type" => "notes", "id" => "n", "items" => ["alpha", "beta"]}

  describe "normalization reaches every container the descent claims" do
    for {label, wrap, _path} <- @placements do
      test "a widget block under #{label} normalizes on write" do
        wrap = unquote(wrap)
        [container] = BlockOps.normalize_render_shapes([wrap.([notes_block()])])

        assert nested_notes_items(container) == [%{"text" => "alpha"}, %{"text" => "beta"}],
               "the widget arm did not reach the nested block"
      end

      test "a text-KEYED inline leaf under #{label} becomes value-keyed" do
        wrap = unquote(wrap)

        paragraph = %{
          "type" => "paragraph",
          "id" => "p",
          "content" => [%{"type" => "text", "text" => "hello"}]
        }

        [container] = BlockOps.normalize_render_shapes([wrap.([paragraph])])

        assert [%{"content" => [%{"type" => "text", "value" => "hello"}]}] =
                 nested_blocks(container)
      end
    end
  end

  describe "the two error walkers reach exactly the same lists" do
    for {label, wrap, path} <- @placements do
      test "a non-map element under #{label} is refused by validate_block_elements/2" do
        wrap = unquote(wrap)

        assert {:error, {:malformed_blocks, %{"blocks" => errors}}} =
                 BlockOps.validate_block_elements([wrap.(["notamap"])])

        assert errors == ["#{unquote(path)}[0] must be an object"]
      end

      test "a legacy list dialect under #{label} is refused by validate_render_shapes/1" do
        wrap = unquote(wrap)
        legacy = %{"type" => "bulletList", "id" => "l", "content" => []}

        assert {:error, {:invalid_paper_structure, details}} =
                 BlockOps.validate_render_shapes([wrap.([legacy])])

        assert details["blocks"] == [
                 "#{unquote(path)}[0].type must be list before the block reaches readers"
               ]
      end
    end
  end

  describe "properties that a widened recursion is easy to lose" do
    test "normalizing an already-normalized document is a byte-identical no-op" do
      doc = mixed_document()
      once = BlockOps.normalize_render_shapes(doc)
      twice = BlockOps.normalize_render_shapes(once)

      # EQUALITY on the second pass, not merely "it did not crash".
      assert twice == once

      # and the first pass must actually have done the WIDENED work, or the
      # assertion above is vacuous — a narrow normalizer is trivially
      # idempotent on the containers it never enters. Naming the widened
      # containers is what makes this test red before the change.
      refute once == doc

      for container <- once do
        assert nested_notes_items(container) == [%{"text" => "alpha"}, %{"text" => "beta"}]
      end
    end

    test "a byline's string items survive the deeper descent byte-identically" do
      byline = %{"type" => "byline", "id" => "b", "items" => ["Pelle Jarl", "May 2026"]}

      for {_label, wrap, _path} <- @placements do
        container = wrap.([byline])
        assert BlockOps.normalize_render_shapes([container]) == [container]
      end

      # and at the top level, where it always held — the control for this pin.
      assert BlockOps.normalize_render_shapes([byline]) == [byline]
    end

    test "a step ROW's own keys are untouched — a row is not a block" do
      row = %{"title" => "One", "id" => "s-0", "note" => "kept", "blocks" => [notes_block()]}
      block = %{"type" => "steps", "id" => "c", "steps" => [row]}

      [%{"steps" => [normalized_row]}] = BlockOps.normalize_render_shapes([block])

      assert Map.delete(normalized_row, "blocks") == Map.delete(row, "blocks")
    end

    test "a steps row carrying BOTH children and blocks keeps the hidden alias" do
      row = %{"title" => "One", "children" => [notes_block()], "blocks" => [notes_block()]}
      block = %{"type" => "steps", "id" => "c", "steps" => [row]}

      [%{"steps" => [normalized_row]}] = BlockOps.normalize_render_shapes([block])

      # `children` is the visible body (visible_body_key/1) and is normalized;
      # the `blocks` compatibility alias is left exactly as stored.
      assert [%{"items" => [%{"text" => "alpha"}, %{"text" => "beta"}]}] =
               normalized_row["children"]

      assert normalized_row["blocks"] == row["blocks"]
    end

    test "an opaque container body is left alone rather than coerced" do
      for block <- [
            %{"type" => "steps", "id" => "c", "steps" => "opaque"},
            %{"type" => "tabs", "id" => "c", "tabs" => %{"not" => "a list"}},
            %{"type" => "columns", "id" => "c", "columns" => ["not a block list"]}
          ] do
        assert BlockOps.normalize_render_shapes([block]) == [block]
        assert BlockOps.validate_block_elements([block]) == :ok
      end
    end
  end

  defp mixed_document do
    [
      wrap_section([notes_block()]),
      wrap_steps([notes_block()]),
      wrap_tabs([notes_block()]),
      wrap_columns([notes_block()])
    ]
  end

  defp nested_blocks(%{"type" => "section", "blocks" => kids}), do: kids
  defp nested_blocks(%{"type" => "steps", "steps" => [%{"blocks" => kids}]}), do: kids
  defp nested_blocks(%{"type" => "tabs", "tabs" => [%{"blocks" => kids}]}), do: kids
  defp nested_blocks(%{"type" => "columns", "columns" => [kids]}), do: kids

  defp nested_notes_items(container) do
    container |> nested_blocks() |> List.first() |> Map.get("items")
  end
end
