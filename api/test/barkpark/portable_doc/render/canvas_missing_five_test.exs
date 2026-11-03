defmodule Barkpark.PortableDoc.Render.CanvasMissingFiveTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.{PaperCanvas, Shared.Paper}

  @blocks [
    %{"id" => "a", "type" => "arrayOf", "label" => "Tags", "value" => ["alpha", "beta"]},
    %{"id" => "c", "type" => "codelist", "label" => "Language", "value" => "nob"},
    %{
      "id" => "o",
      "type" => "composite",
      "label" => "SEO",
      "fields" => [%{"name" => "title", "title" => "Meta title"}],
      "value" => %{"title" => "Field notes"}
    },
    %{
      "id" => "l",
      "type" => "localizedText",
      "label" => "Tagline",
      "languages" => ["nob", "eng"],
      "value" => %{"nob" => "Hei", "eng" => "Hello"}
    },
    %{
      "id" => "pre-gate-badge",
      "type" => "pre-gate-badge",
      "anchor" => "byline",
      "label" => "Published before the block gate",
      "title" => "Historical compatibility notice.",
      "tone" => "warning"
    }
  ]

  test "all five use the canonical reader producer on the canvas paint channel" do
    for block <- @blocks do
      render = Paper.fleet_render(block, %{})

      assert render["block_id"] == block["id"]
      assert render["html"] == Render.render_block(block, %{style: :article})
      assert render["html"] != ""
    end
  end

  test "pre-gate chrome joins a run while structured fields retain their contextual editors" do
    [array, codelist, composite, localized, badge] = @blocks

    assert PaperCanvas.canvas?(badge)
    refute PaperCanvas.canvas?(array)
    refute PaperCanvas.canvas?(codelist)
    refute PaperCanvas.canvas?(composite)
    refute PaperCanvas.canvas?(localized)

    assert Enum.all?(@blocks, &Paper.fleet_block?/1)
  end
end
