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

  # The `:article` composer reads `lang` for ONE thing since Barkdown plan #27: it rides as a
  # `data-lang` attribute on the <pre>, so the reader's client pass (/assets/bp-paper-code.js, the
  # tokenizer the canvas uses) can paint tokens. The source is composed verbatim regardless, the
  # retired `language` key is still never read, and the email arm reads neither key.
  test "the Elixir code composer reads `lang` only as data-lang; `language` and none compose identically" do
    for style <- [:article, :email] do
      htmls =
        Enum.map(@cases, fn c -> Compose.compose_block(c["block"], style) end)

      strip = fn composed ->
        Map.update(composed, "html", nil, fn html ->
          String.replace(html, ~r/ data-lang="[^"]*"/, "")
        end)
      end

      first = strip.(hd(htmls))

      for {composed, i} <- Enum.with_index(htmls) do
        assert strip.(composed) == first,
               "case #{i}: style #{inspect(style)} composed #{inspect(composed)} — " <>
                 "differs (beyond data-lang) from the lang-bearing case #{inspect(first)}; the " <>
                 "Elixir code renderer must branch on NEITHER `lang` nor `language` for its source"
      end

      # Only the case that spells `lang` carries the attribute — the retired alias never does.
      for {c, composed} <- Enum.zip(@cases, htmls) do
        html = Map.get(composed, "html", "")
        lang = Map.get(c["block"], "lang")
        has_lang? = is_binary(lang) and lang != ""

        if style == :article and has_lang? do
          assert html =~ ~s( data-lang="#{lang}"), "case #{c["name"]}: data-lang expected"
        else
          refute html =~ "data-lang",
                 "case #{c["name"]} (#{inspect(style)}): data-lang must not appear"
        end
      end
    end
  end
end
