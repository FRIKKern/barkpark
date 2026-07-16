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
    * SCOPE — the array is exactly the 46 in-scope types: both members of all 3
      alias pairs present, none of the 14 excluded, no `quiz`/`onix`.

  Regenerate with `MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity` whenever
  this reds, then re-run `bash scripts/pd-parity-completeness.sh`.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity

  @api_dir Path.expand("../../../support/fixtures/pd-parity", __DIR__)
  @js_dir Path.expand("../../../../../js/packages/react/tests/fixtures/pd-golden", __DIR__)

  defp decode!(dir, type),
    do: dir |> Path.join(GenPdParity.filename(type)) |> File.read!() |> Jason.decode!()

  # ── scope: exactly the 46 in-scope types ─────────────────────────────────────

  test "the array holds exactly 46 in-scope types" do
    assert length(GenPdParity.types()) == 46
  end

  test "both members of all 3 alias pairs are present" do
    for {a, b} <- GenPdParity.alias_pairs() do
      assert a in GenPdParity.types(), "alias member #{a} missing"
      assert b in GenPdParity.types(), "alias member #{b} missing"
    end
  end

  test "none of the 14 excluded types (nor quiz/onix) are in the array" do
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
      assert fx["shape"] != [], "#{@type_slug} rendered to an empty shape — check the authored input"
    end
  end
end
