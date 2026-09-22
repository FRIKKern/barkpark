defmodule Barkpark.PortableDoc.BpmlStatVerdictTest do
  @moduledoc """
  task-8bdef19b5acef8a8 — BPML dropped a stat's `verdict` on round-trip.

  The stat VERDICT data path shipped in two of its three legs: `render/data_viz.ex`
  `stat_html/1` paints `.bp-stat__v--loss` / `--peace` off the key, and
  `js/packages/react/src/blocks/dataviz.ts` mirrors it. BPML was the missing leg —
  `<stat>` spelled `label value denom` only, so a verdict-carrying stat came back
  from a print/parse round trip with the key GONE and its digits repainted
  `--paper-ink`, with no error anywhere.

  Two arms, deliberately:

    * **THE RED ARM** (`round-trips a stat's verdict`) — fails the moment
      `"verdict"` is removed from either `printer.ex` `stat_item/1`'s attr row or
      `parser.ex`'s `"stat"` row / `stat_item_builder/3`.
    * **THE QUIET ARM** (`a verdict-free stat is byte-identical`) — the widening
      is additive: a stat with no verdict prints exactly the bytes it printed
      before, so the arm stays green across the fix AND across its revert. It is
      the control that proves the red arm is measuring the verdict and not the
      element.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml

  defp stats(items), do: [%{"id" => "s1", "type" => "stats", "items" => items}]

  describe "the verdict survives BPML" do
    test "round-trips a stat's verdict — loss and peace, key intact" do
      blocks =
        stats([
          %{"label" => "regressions", "value" => "7", "verdict" => "loss"},
          %{"label" => "quiet nights", "value" => "12", "denom" => "/14", "verdict" => "peace"}
        ])

      bpml = Bpml.print_blocks(blocks)

      assert bpml =~ ~s|verdict="loss"|
      assert bpml =~ ~s|verdict="peace"|

      assert {:ok, parsed} = Bpml.parse_blocks(bpml)
      assert parsed == blocks

      # stated positively, so a future "items round-trip" that silently dropped
      # every attribute could not pass this by comparing two empty maps.
      [one, two] = hd(parsed)["items"]
      assert one["verdict"] == "loss"
      assert two["verdict"] == "peace"
      assert two["denom"] == "/14"
    end

    test "an off-vocabulary verdict is carried losslessly, not swallowed" do
      blocks = stats([%{"label" => "mood", "value" => "3", "verdict" => "elated"}])

      assert {:ok, parsed} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()
      assert parsed == blocks
    end

    test "verdict rides the stat-grid element too — one <stat> spells both" do
      blocks = [
        %{
          "id" => "g1",
          "type" => "stat-grid",
          "items" => [%{"label" => "losses", "value" => "2", "verdict" => "loss"}]
        }
      ]

      bpml = Bpml.print_blocks(blocks)
      assert bpml =~ ~s|verdict="loss"|
      assert {:ok, parsed} = Bpml.parse_blocks(bpml)
      assert hd(hd(parsed)["items"])["verdict"] == "loss"
    end

    test "/v1/capabilities publishes verdict in the <stat> row" do
      assert "verdict" in Bpml.vocabulary()["blocks"]["stat"]
    end
  end

  describe "the widening is additive (controls)" do
    test "a verdict-free stat is byte-identical — attribute order unchanged" do
      blocks = stats([%{"label" => "p95 latency", "value" => "182ms", "denom" => "/200ms"}])

      assert Bpml.print_blocks(blocks) =~
               ~s|<stat label="p95 latency" value="182ms" denom="/200ms"></stat>|

      assert {:ok, ^blocks} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()
    end

    test "caption/note keep their typed refusal — this row widened ONE attribute" do
      assert_raise Barkpark.PortableDoc.Bpml.UnprintableError, fn ->
        Bpml.print_blocks(stats([%{"label" => "x", "value" => "1", "caption" => "nope"}]))
      end
    end
  end
end
