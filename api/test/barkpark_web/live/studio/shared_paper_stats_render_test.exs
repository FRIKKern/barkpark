defmodule BarkparkWeb.Studio.SharedPaperStatsRenderTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "Stats paint carries its exact authored source without changing reader HTML" do
    item = %{"value" => 1.25, "label" => " Authored label ", "source" => "commit:1234567"}

    for type <- ~w(stat stats stat-grid) do
      block =
        if type == "stat",
          do: Map.merge(item, %{"id" => "stat", "type" => type}),
          else: %{"id" => "stats", "type" => type, "items" => [nil, item], "custom" => true}

      render = Paper.fleet_render(block, %{})
      assert render["source_block"] === block
      assert render["html"] == Render.render_block(block, %{style: :article})
      assert render["html"] =~ "Authored label"
    end
  end

  test "other fleet payloads retain the existing two-field contract" do
    block = %{"id" => "notes", "type" => "notes", "items" => []}

    assert Paper.fleet_render(block, %{}) == %{
             "block_id" => "notes",
             "html" => Render.render_block(block, %{style: :article})
           }
  end
end
