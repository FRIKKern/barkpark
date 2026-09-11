defmodule Barkpark.PortableDoc.Render.InlineCodeSourceParityTest do
  @moduledoc """
  The Elixir leg of the INLINE `code` source parity lock (task-e4833f198e293ed1).

  Three engines render an inline code chip and they all read ONE fixture file —
  `api/test/support/fixtures/inline-code-source.json`:

    Elixir  api/lib/barkpark/portable_doc/render/inline.ex   `inline_code_source/1`
            tested HERE
    JS      js/packages/react/src/inline.tsx                 `inlineCodeSource`
            tested by js/packages/react/tests/inline-code-source.parity.test.ts
    Go      internal/pdrender/inline.go                      `inlineCodeSource`
            tested by internal/pdrender/inline_code_source_parity_test.go

  ONE file, not three generated mirrors — a mirror set drifts the moment one side
  is regenerated and the others are not, which is exactly the bug this row
  exists to close: react shipped the value-or-children law while this module and
  the Go TUI still read `value` only, so 66 published paragraphs rendered a
  chip with no body everywhere but the web.

  DRIFT PROOF: delete the `"" -> flatten_inline_text(...)` arm of
  `inline_code_source/1` and the children-shaped cases red HERE while the JS and
  Go legs stay green. No engine can move alone.
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
             "inline-code-source.json"
           ])
           |> Path.expand()

  setup_all do
    %{"cases" => cases} = @fixture |> File.read!() |> Jason.decode!()
    # Guard the fixture itself: an empty or shrunken case list would make every
    # assertion below vacuously pass.
    assert length(cases) >= 13
    {:ok, cases: cases}
  end

  test "every fixture case composes its recorded source", %{cases: cases} do
    for %{"name" => name, "node" => node, "source" => expected} <- cases do
      assert Inline.inline_code_source(node) == expected,
             "inline_code_source/1 disagreed with the fixture for: #{name}"

      assert Inline.compose_inline(node, false) == %{
               "kind" => "PdInlineCode",
               "value" => expected
             },
             "compose_inline/2 disagreed with the fixture for: #{name}"
    end
  end

  test "the children fall-through is REACHED by at least one fixture case", %{cases: cases} do
    # Without this the suite could stay green on a value-only fixture while the
    # very arm the row is about was never exercised.
    children_cases =
      Enum.filter(cases, fn %{"node" => n, "source" => src} ->
        Map.get(n, "children") != nil and src != "" and
          Inline.inline_code_source(Map.delete(n, "children")) != src
      end)

    assert length(children_cases) >= 6
  end

  test "a whitespace-only value wins over children (first NON-EMPTY, not non-blank)" do
    node = %{
      "type" => "code",
      "value" => " ",
      "children" => [%{"type" => "text", "value" => "never"}]
    }

    assert Inline.inline_code_source(node) == " "
  end
end
