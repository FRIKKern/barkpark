defmodule BarkparkWeb.Studio.SharedPaperSpecialtyRenderTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @types ~w(api-endpoint bar-chart code-tabs criteria-progress gauge-list route)

  test "all six specialty blocks use the canonical reader producer on the host-paint seam" do
    for type <- @types do
      block =
        "priv/portable_doc/goldens/blocks/#{type}.golden.json"
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("input")
        |> Map.put("id", "specialty-#{type}")

      assert Paper.fleet_block?(block), "expected #{type} to be admitted to host paint"

      assert Paper.fleet_render(block, %{}) == %{
               "block_id" => "specialty-#{type}",
               "html" => Render.render_block(block, %{style: :article})
             }
    end
  end

  test "an unrelated block is not admitted by the specialty set" do
    refute Paper.fleet_block?(%{"id" => "x", "type" => "not-a-specialty"})
  end
end
