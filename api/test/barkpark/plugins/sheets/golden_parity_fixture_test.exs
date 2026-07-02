defmodule Barkpark.Plugins.Sheets.GoldenParityFixtureTest do
  @moduledoc """
  Freshness lock for the cross-surface golden parity fixture — the Elixir
  source-of-truth end of the spine `Core.snapshot_for` + `Fmt.display` -> one
  committed fixture -> {api tests, web SDK, internal/pdrender TUI}.

  A `Fmt.display` change, an `sv` bump, or a snapshot-synthesis change that ships
  WITHOUT regenerating the fixture would let the TUI (and web) render a stale /
  wrong grid with every gate otherwise green. This suite reds instead: it
  regenerates the fixture in-memory and asserts term-equality with the committed
  api mirror, asserts the three mirrors are byte-for-byte the same fixture, and
  asserts the fixture's stamped `sv` matches the live schema version.

  Regenerate with `mix barkpark.sheets.gen_golden_parity` (writes all three
  mirrors) whenever this reds.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Core
  alias Mix.Tasks.Barkpark.Sheets.GenGoldenParity

  @api_path Path.expand("../../../support/fixtures/sheet-golden-parity.json", __DIR__)
  @web_path Path.expand(
              "../../../../../web/__tests__/fixtures/sheet-golden-parity.json",
              __DIR__
            )
  @go_path Path.expand(
             "../../../../../internal/pdrender/testdata/sheet-golden-parity.json",
             __DIR__
           )

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()

  test "committed api mirror equals a fresh regeneration (build/0)" do
    committed = decode!(@api_path)

    # build/0 emits only JSON-safe terms, so a Jason encode->decode round-trip is
    # the identity — comparing the decoded committed fixture to build/0 directly
    # is exactly the "does the file match the generator" check.
    assert committed == GenGoldenParity.build(),
           "sheet-golden-parity.json is stale — " <>
             "run `mix barkpark.sheets.gen_golden_parity` and re-verify all five surfaces."
  end

  test "the three mirrors decode term-identical" do
    api = decode!(@api_path)
    web = decode!(@web_path)
    go = decode!(@go_path)

    assert api == web,
           "web mirror drifted from api mirror — run `mix barkpark.sheets.gen_golden_parity`."

    assert api == go,
           "internal/pdrender mirror drifted from api mirror — run `mix barkpark.sheets.gen_golden_parity`."
  end

  test "fixture sv matches the live snapshot schema version" do
    assert decode!(@api_path)["sv"] == Core.snapshot_schema_version()
  end
end
