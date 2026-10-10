defmodule Barkpark.PortableDoc.Render.PdGoldenParityTest do
  @moduledoc """
  Elixir source-of-truth leg of the cross-surface **PortableDoc render-parity**
  spine (render-path unification Wave 1): the real `:article` emitter → one frozen
  golden per in-scope block type → the canonical JS `PortableDoc` renderer
  (`@barkpark/react`) proven shape-equal to it.

  A `compose.ex`/`walk.ex`/emitter change that ships WITHOUT regenerating the
  fixtures would let the JS renderer chase a stale golden with every gate otherwise
  green. This suite reds instead:

    * FRESHNESS — the committed api mirror equals a fresh `build/1` (regenerated
      in-memory; no `Mix.Task`).
    * MIRROR IDENTITY — the api + js mirrors decode term-identical (no drift
      between the surface copies).
    * SCOPE — the array is exactly the in-scope census (`EXPECTED_COUNT` in
      scripts/pd-parity-completeness.sh — do not hand-count here): both members
      of all 3 alias pairs present, none of the excluded, no `quiz`/`onix`.

  Regenerate with `MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity` whenever
  this reds, then re-run `bash scripts/pd-parity-completeness.sh`.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity

  @api_dir Path.expand("../../../support/fixtures/pd-parity", __DIR__)
  @js_dir Path.expand("../../../../../js/packages/react/tests/fixtures/pd-golden", __DIR__)

  defp decode!(dir, type),
    do: dir |> Path.join(GenPdParity.filename(type)) |> File.read!() |> Jason.decode!()

  # ── scope: exactly the in-scope census ───────────────────────────────────────

  test "the array holds exactly the in-scope census" do
    # scaffy:add-block-type Diff MARK:parity-count-test-diff
    # scaffy:add-block-type Filetree MARK:parity-count-test-filetree
    # scaffy:add-block-type Blockquote MARK:parity-count-test-blockquote
    # scaffy:add-block-type Toc MARK:parity-count-test-toc
    # scaffy:add-block-type Steps MARK:parity-count-test-steps
    # scaffy:add-block-type Footnote MARK:parity-count-test-footnote
    # scaffy:add-block-type Expandable MARK:parity-count-test-expandable
    # scaffy:add-block-type BarChart MARK:parity-count-test-bar-chart
    # scaffy:add-block-type Equation MARK:parity-count-test-equation
    # scaffy:add-block-type CriteriaProgress MARK:parity-count-test-criteria-progress
    # scaffy:add-block-type Video MARK:parity-count-test-video
    # scaffy:add-block-type ApiEndpoint MARK:parity-count-test-api-endpoint
    # scaffy:add-block-type CodeTabs MARK:parity-count-test-code-tabs
    # scaffy:add-block-type Tabs MARK:parity-count-test-tabs
    # jdf-bl-historiene-renderer-reconciliation: +duel +lineage
    # docgates-s27: +pre-gate-badge (#17199's compose.ex clause, goldenless until now)
    # task-7375ba22758155fa: +14 schema field blocks (65 -> 79)
    assert length(GenPdParity.types()) == 79
  end

  test "both members of all 3 alias pairs are present" do
    for {a, b} <- GenPdParity.alias_pairs() do
      assert a in GenPdParity.types(), "alias member #{a} missing"
      assert b in GenPdParity.types(), "alias member #{b} missing"
    end
  end

  test "none of the excluded types (nor quiz/onix) are in the array" do
    for t <- GenPdParity.excluded() ++ ["quiz", "onix"] do
      refute t in GenPdParity.types(), "#{t} must not be in the kitchen-sink array"
    end
  end

  # ── freshness + mirror identity, per type ────────────────────────────────────

  for type <- GenPdParity.types() do
    @type_slug type

    test "#{type}: committed api mirror equals a fresh build/1" do
      assert decode!(@api_dir, @type_slug) == GenPdParity.build(@type_slug),
             "#{@type_slug}.golden.json is stale — " <>
               "run `MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity` and re-verify the JS harness."
    end

    test "#{type}: the two mirrors decode term-identical" do
      assert decode!(@api_dir, @type_slug) == decode!(@js_dir, @type_slug),
             "js mirror drifted from api mirror for #{@type_slug}"
    end

    test "#{type}: the frozen fixture carries a non-empty shape projection" do
      fx = decode!(@api_dir, @type_slug)
      assert is_binary(fx["expectedHtml"])
      assert is_list(fx["shape"])

      assert fx["shape"] != [],
             "#{@type_slug} rendered to an empty shape — check the authored input"
    end
  end

  # ── the locale golden (task-8e96278fc4ee7097) ────────────────────────────────

  defp decode_locale!(dir, locale),
    do: dir |> Path.join(GenPdParity.locale_filename(locale)) |> File.read!() |> Jason.decode!()

  for locale <- GenPdParity.locales() do
    @locale locale

    test "#{locale} locale golden: committed api mirror equals a fresh build_locale/1" do
      assert decode_locale!(@api_dir, @locale) == GenPdParity.build_locale(@locale),
             "#{GenPdParity.locale_filename(@locale)} is stale — " <>
               "run `MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity`."
    end

    test "#{locale} locale golden: the two mirrors decode term-identical" do
      assert decode_locale!(@api_dir, @locale) == decode_locale!(@js_dir, @locale)
    end
  end

  test "nb-NO: the renderer's own words come out Norwegian, and the same inputs without :locale stay English" do
    fx = decode_locale!(@api_dir, "nb-NO")

    for word <- ~w(Ja Nei UTKAST Advarsel) ++ ["åpen", "pågår", "Kriterier · 1/2"] do
      assert fx["expectedHtml"] =~ word, "nb golden lacks #{inspect(word)}"
    end

    english =
      Enum.map_join(
        fx["inputs"],
        &Barkpark.PortableDoc.Render.render_block(&1, %{style: :article})
      )

    for word <- ~w(Yes No DRAFT Warning) ++ ["open", "Criteria · 1/2"] do
      assert english =~ word, "default render lacks #{inspect(word)}"
    end

    refute english =~ "Nei"

    assert english ==
             Enum.map_join(
               fx["inputs"],
               &Barkpark.PortableDoc.Render.render_block(&1, %{style: :article, locale: "en"})
             )
  end

  test "every word the nb golden hands the JS renderer is translated" do
    fx = decode_locale!(@api_dir, "nb-NO")

    # Words that are the same in both languages.
    same = ~w(Info Papers Total)

    untranslated =
      for {en, nb} <- fx["strings"], en == nb, en not in same, do: en

    assert untranslated == [], "nb msgstr missing for: #{inspect(untranslated)}"
  end
end
