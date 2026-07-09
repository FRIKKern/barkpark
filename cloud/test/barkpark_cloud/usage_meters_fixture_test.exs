defmodule BarkparkCloud.UsageMetersFixtureTest do
  @moduledoc """
  The three-runtime meter-vocabulary tripwire, Elixir leg (charter OC12 /
  wave-2 watch-item (c)). `priv/static/__fixtures__/usage_meters.json` is the ONE
  committed list of meter names shared by three renderers — the SPA Usage tab,
  the `bp cloud usage` CLI twin, and this control-plane composer. Each asserts
  its own vocabulary against the same bytes, so a meter added / renamed in one
  runtime that forgets the others fails a test instead of drifting silently.

  This leg pins the fixture's meter-NAME SET to `Usage.compose/1`'s meter keys —
  set only, order- and label-free (Elixir emits an unordered map with no labels;
  the SPA owns display order, the fixture owns labels). Prior art: the D32
  `verify_probes.json` binding in `verify_test.exs`.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Usage

  @fixture_path Path.expand("../../priv/static/__fixtures__/usage_meters.json", __DIR__)

  test "the fixture's meter-name set is EXACTLY Usage.compose/1's meter keys" do
    fixture_names =
      @fixture_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("meters")
      |> Enum.map(&Map.fetch!(&1, "name"))
      |> MapSet.new()

    composed_keys =
      Usage.compose().meters
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> MapSet.new()

    assert fixture_names == composed_keys,
           """
           Meter vocabulary drift between usage_meters.json and Usage.compose/1.
             only in fixture:  #{inspect(MapSet.difference(fixture_names, composed_keys))}
             only in composer: #{inspect(MapSet.difference(composed_keys, fixture_names))}
           Add / rename the meter in BOTH (and the SPA + CLI) or neither.
           """
  end
end
