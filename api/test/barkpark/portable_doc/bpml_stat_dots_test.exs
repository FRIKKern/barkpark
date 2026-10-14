defmodule Barkpark.PortableDoc.BpmlStatDotsTest do
  @moduledoc """
  pe-bl-stat-tile-dots — a stat's trial dots survive BPML.

  `dots: %{"on" => 2, "of" => 10}` travels as `<stat dots="2/10">`. Remove
  `"dots"` from `printer.ex` `stat_item/1`'s attr row, or `put_dots_attr/2` from
  `parser.ex` `stat_item_builder/3`, and the round-trip test reds. The control:
  a dot-less stat prints no `dots=` at all.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml
  alias Barkpark.PortableDoc.Bpml.UnprintableError

  defp stats(items), do: [%{"id" => "s1", "type" => "stats", "items" => items}]

  test "round-trips a stat's dots as on/of, map intact" do
    blocks = stats([%{"label" => "trials", "value" => "2", "dots" => %{"on" => 2, "of" => 10}}])

    bpml = Bpml.print_blocks(blocks)
    assert bpml =~ ~s|dots="2/10"|

    assert {:ok, parsed} = Bpml.parse_blocks(bpml)
    assert parsed == blocks
    assert hd(hd(parsed)["items"])["dots"] == %{"on" => 2, "of" => 10}
  end

  test "text that is not two integers stays the string it was" do
    blocks = stats([%{"value" => "2", "dots" => "some"}])
    assert {:ok, ^blocks} = blocks |> Bpml.print_blocks() |> Bpml.parse_blocks()
  end

  test "a dots map of any other shape refuses instead of dropping the key" do
    for dots <- [%{"on" => 2.5, "of" => 10}, %{"on" => 2, "of" => 10, "x" => 1}, [2, 10]] do
      assert_raise UnprintableError, fn ->
        Bpml.print_blocks(stats([%{"value" => "2", "dots" => dots}]))
      end
    end
  end

  test "control: a dot-less stat prints no dots attribute" do
    refute Bpml.print_blocks(stats([%{"value" => "2"}])) =~ "dots="
  end

  test "/v1/capabilities publishes dots in the <stat> row" do
    assert "dots" in Bpml.vocabulary()["blocks"]["stat"]
  end
end
