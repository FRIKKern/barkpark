defmodule Barkpark.PortableDoc.Render.InlineBlockWrapperParityTest do
  @moduledoc """
  The Elixir leg of the BLOCK-WRAPPER-IN-AN-INLINE-ARRAY parity lock
  (task-3fd604e7c89d6150, sibling of task-9cab47ce042ccdfb / PR #15701).

  Three engines walk a run of inline nodes and they all read ONE fixture file —
  `api/test/support/fixtures/inline-block-wrapper.json`:

    Elixir  api/lib/barkpark/portable_doc/render/inline.ex   `unwrap_block_wrappers/1`
            tested HERE
    JS      js/packages/react/src/inline.tsx                 `unwrapBlockWrappers`
            tested by js/packages/react/tests/inline-block-wrapper.parity.test.ts
    Go      internal/pdrender/inline.go                      `unwrapBlockWrappers`
            tested by internal/pdrender/inline_block_wrapper_parity_test.go

  ONE file, not three generated mirrors — a mirror set drifts the moment one side
  is regenerated and the others are not, which is exactly the bug this row exists
  to close: THIS engine shipped the unwrap on 2026-09-03 and the other two stayed
  blank on the same 75 published list items until the row that added this file.

  `inline_block_wrapper_unwrap_test.exs` (from #15701) is the behaviour test for
  this module and stays as it is; this file is the CROSS-ENGINE lock — its job is
  that the fixture the Go and JS legs read describes THIS engine's behaviour, so
  none of the three can move alone.

  DRIFT PROOF: delete the `unwrap_block_wrappers/1` call from
  `compose_inline_children/1` and the seven wrapper-shaped cases red HERE while
  the Go and JS legs stay green.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Inline

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "..",
             "support",
             "fixtures",
             "inline-block-wrapper.json"
           ])
           |> Path.expand()

  setup_all do
    %{"cases" => cases} = @fixture |> File.read!() |> Jason.decode!()
    # Guard the fixture itself: an empty or shrunken case list would make every
    # assertion below vacuously pass.
    assert length(cases) >= 13
    {:ok, cases: cases}
  end

  # The VISIBLE text of a composed inline run. The Go leg strips ANSI and the JS
  # leg strips tags, so all three compare the SAME string.
  defp visible(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &visible/1)
  defp visible(s) when is_binary(s), do: s
  defp visible(n) when is_number(n), do: to_string(n)
  defp visible(%{"children" => kids}) when is_list(kids), do: visible(kids)
  defp visible(%{"value" => v}) when is_binary(v), do: v
  defp visible(_), do: ""

  test "every fixture case composes to its recorded visible text", %{cases: cases} do
    for %{"name" => name, "nodes" => nodes, "text" => text} <- cases do
      got = nodes |> Inline.compose_inline_children() |> visible()

      assert got == text,
             "inline run disagreed with the shared fixture for #{inspect(name)}:\n" <>
               " got  #{inspect(got)}\n want #{inspect(text)}"
    end
  end

  test "at least seven cases DEPEND on the unwrap (the mutation control)", %{cases: cases} do
    # The pre-fix walk, reproduced here: map compose_inline/2 over the run with
    # NO unwrap. If this count drops, the assertion above was passing for some
    # other reason and proves nothing about unwrap_block_wrappers/1.
    depends =
      Enum.count(cases, fn %{"nodes" => nodes, "text" => text} ->
        text != "" and
          Enum.map_join(nodes, "", &visible(Inline.compose_inline(&1, false))) != text
      end)

    assert depends >= 7
  end

  describe "the bounds carried into the two mirror engines" do
    test "a wrapper with EMPTY content is not unwrapped" do
      assert [""] = Inline.compose_inline_children([%{"type" => "paragraph", "content" => []}])
    end

    test "a node whose content is not a list is not unwrapped" do
      assert [""] =
               Inline.compose_inline_children([
                 %{"type" => "paragraph", "content" => "not a list"}
               ])
    end

    test "ONE level only — the inner wrapper is not unwrapped a second time" do
      inner = %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "deep"}]}

      assert [""] =
               Inline.compose_inline_children([
                 %{"type" => "paragraph", "content" => [inner]}
               ])
    end

    test "a MARK node's own children are NOT unwrapped" do
      # strong/em/link map compose_inline/2 over their children rather than
      # routing them back through compose_inline_children/1 — the Go leg pins
      # this with TestMarkChildrenAreNotUnwrapped and the JS leg with
      # renderInlineChildren.
      nodes = [
        %{
          "type" => "strong",
          "children" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "under a mark"}]}
          ]
        }
      ]

      assert nodes |> Inline.compose_inline_children() |> visible() == ""
    end
  end
end
