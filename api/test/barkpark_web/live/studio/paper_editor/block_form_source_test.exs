defmodule BarkparkWeb.Studio.PaperEditor.BlockFormSourceTest do
  use ExUnit.Case, async: true
  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "fingerprinted source and resolver share every logical field" do
    params = %{
      "block_id" => "number",
      "value" => "4",
      "if_rev" => 2,
      "request_id" => "request",
      "unknown" => "retained"
    }

    source = Blocks.block_form_source(params)
    assert source == Map.drop(params, ["if_rev", "request_id"])
    assert source["unknown"] == "retained"

    assert {:ok, %{"patch" => %{"value" => 4}}} =
             Blocks.resolve_block_form([%{"id" => "number", "type" => "field-number"}], source)
  end

  test "only actual field validation errors are recoverable validation failures" do
    source = %{"block_id" => "number", "value" => "not-a-number"}

    assert {:error, {:source_validation, :invalid_number}} =
             Blocks.resolve_block_form([%{"id" => "number", "type" => "field-number"}], source)

    assert {:error, :block_not_found} = Blocks.resolve_block_form([], source)
    assert {:error, :invalid_block_form} = Blocks.resolve_block_form([], %{})
  end
end
