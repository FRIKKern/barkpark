defmodule Barkpark.PortableDoc.BpmlTocEditingTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Bpml

  for sticky <- [true, false] do
    @sticky sticky
    test "table-of-contents authored fields retain sticky=#{sticky} through BPML" do
      block = %{
        "id" => "outline",
        "type" => "toc",
        "depth" => 3,
        "numbered" => true,
        "sticky" => @sticky,
        "items" => [
          %{"text" => "Evidence & checks", "level" => 1, "anchor" => "evidence"},
          %{"text" => "Nested detail", "level" => 2, "anchor" => "detail"}
        ]
      }

      printed = Bpml.print_blocks([block])
      assert {:ok, [^block]} = Bpml.parse_blocks(printed)
      assert Bpml.print_blocks([block]) == printed
    end
  end

  test "legacy table of contents does not gain an unauthored sticky field" do
    block = %{"type" => "toc", "items" => []}
    assert {:ok, [^block]} = block |> then(&Bpml.print_blocks([&1])) |> Bpml.parse_blocks()
  end
end
