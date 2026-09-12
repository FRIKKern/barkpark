defmodule Barkpark.PortableDoc.Render.CodeBlockLangParityTest do
  @moduledoc """
  The Elixir leg of the code-block LANGUAGE-FIELD parity lock
  (task-6e6b2661d201ccc0).

  All three render engines read ONE fixture file —
  `api/test/support/fixtures/code-block-lang-parity.json`. The Go leg is
  `internal/pdrender/code_block_lang_parity_test.go`; the JS leg is
  `js/packages/react/tests/code-block-lang.parity.test.ts`.

  The language field is `lang`. `language` is a RETIRED alias: only the Go TUI
  engine ever consumed a code-block language at render (to name the chroma lexer)
  and it now reads `lang` alone. The Elixir standalone `code` composer
  (`Compose.compose_block(%{"type" => "code"}, …)`) renders the `value` and is
  language-AGNOSTIC — it reads NEITHER `lang` nor `language`. This leg proves
  that: a block carrying `lang`, one carrying the retired `language`, and one
  carrying neither compose to IDENTICAL html (every fixture case shares one
  value). So the Elixir engine can never drift to preferring `language` the way
  the Go engine had — there is no branch to drift.

  (`Map.get(block, "language", "")` in `Render.Compose` belongs to `code-tabs`
  TAB ENTRIES, a different block type — see `code_tab_entries/1`.)
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose

  @fixture Path.expand("../../../support/fixtures/code-block-lang-parity.json", __DIR__)

  @external_resource @fixture

  @doc_json @fixture |> File.read!() |> Jason.decode!()
  @cases Map.fetch!(@doc_json, "cases")

  test "the shared fixture is the one all three engines read, spelling the field `lang`" do
    assert File.exists?(@fixture),
           "the shared code-lang fixture is missing: #{@fixture} — " <>
             "internal/pdrender/code_block_lang_parity_test.go reads the same path"

    assert Map.fetch!(@doc_json, "language_field") == "lang"
    assert Map.fetch!(@doc_json, "retired_alias") == "language"
    assert length(@cases) >= 3
  end

  for {c, i} <- Enum.with_index(@cases) do
    @case c
    @idx i

    test "#{i}: #{c["name"]} — :article composes the code source verbatim" do
      composed = Compose.compose_block(@case["block"], :article)
      html = Map.get(composed, "html", "")

      refute html == "",
             "case #{@idx} (#{@case["name"]}): expected content, got an EMPTY compose"

      assert String.contains?(html, @case["source"]),
             "case #{@idx} (#{@case["name"]}): expected source #{inspect(@case["source"])} " <>
               "in the composed html, got #{inspect(html)}"
    end
  end

  test "the Elixir code composer is language-agnostic: lang / language / neither compose identically" do
    # Every case shares one `value`, differing only in the language key
    # (`lang`, the retired `language`, or none). If the composer read either
    # key its output would differ across cases; it does not.
    for style <- [:article, :email] do
      htmls =
        Enum.map(@cases, fn c -> Compose.compose_block(c["block"], style) end)

      first = hd(htmls)

      for {composed, i} <- Enum.with_index(htmls) do
        assert composed == first,
               "case #{i}: style #{inspect(style)} composed #{inspect(composed)} — " <>
                 "differs from the lang-bearing case #{inspect(first)}; the Elixir code " <>
                 "renderer must branch on NEITHER `lang` nor `language`"
      end
    end
  end
end
