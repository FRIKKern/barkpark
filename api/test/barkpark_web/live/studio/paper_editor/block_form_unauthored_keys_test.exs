defmodule BarkparkWeb.Studio.PaperEditor.BlockFormUnauthoredKeysTest do
  @moduledoc """
  task-56bafb69a8a1f250: a block form submits every control it renders, so
  editing one visible field wrote the other controls' blank defaults as keys the
  author never set. The resolved patch must leave absent optional keys absent
  and still carry real changes, including clearing an authored value.
  """
  use ExUnit.Case, async: true
  alias BarkparkWeb.Studio.StudioLive.Blocks

  @video %{
    "id" => "t-video",
    "type" => "video",
    "src" => "https://ex.com/demo.mp4",
    "poster" => "https://ex.com/demo-poster.jpg",
    "captions" => [%{"lang" => "en", "src" => "https://ex.com/en.vtt"}]
  }

  @number %{
    "id" => "t-field-number",
    "type" => "field-number",
    "label" => "Print run",
    "value" => 1200
  }

  defp patch(block, source) do
    {:ok, %{"op" => "patch-block", "patch" => patch}} = Blocks.resolve_block_form([block], source)
    patch
  end

  test "editing a video's source adds no loop key" do
    # The exact paper-block-autosave payload the reader sent.
    source = %{
      "block_id" => "t-video",
      "caption-count" => "1",
      "src" => "https://ex.com/demoQz.mp4",
      "poster" => "https://ex.com/demo-poster.jpg",
      "caption-0-lang" => "en",
      "caption-0-src" => "https://ex.com/en.vtt"
    }

    patch = patch(@video, source)
    assert patch["src"] == "https://ex.com/demoQz.mp4"
    refute Map.has_key?(patch, "loop")

    assert Map.merge(@video, patch) |> Map.keys() |> Enum.sort() ==
             @video |> Map.keys() |> Enum.sort()
  end

  test "editing a field-number label adds no min, max, step or unit key" do
    source = %{
      "block_id" => "t-field-number",
      "label" => "Print runQz",
      "value" => "1200",
      "min" => "",
      "max" => "",
      "step" => "",
      "unit" => ""
    }

    assert patch(@number, source) == %{"label" => "Print runQz", "value" => 1200}
  end

  test "a value the author sets on an absent key is written" do
    source = %{
      "block_id" => "t-field-number",
      "label" => "Print run",
      "value" => "1200",
      "min" => "0",
      "max" => "",
      "step" => "",
      "unit" => "copies"
    }

    assert patch(@number, source) == %{
             "label" => "Print run",
             "value" => 1200,
             "min" => 0,
             "unit" => "copies"
           }

    looped = patch(@video, %{"block_id" => "t-video", "src" => @video["src"], "loop" => "true"})
    assert looped["loop"] == true
  end

  test "clearing an authored key still lands" do
    authored = Map.merge(@number, %{"unit" => "copies", "min" => 0, "loop" => true})

    source = %{
      "block_id" => "t-field-number",
      "label" => "Print run",
      "value" => "1200",
      "min" => "",
      "max" => "",
      "step" => "",
      "unit" => ""
    }

    patch = patch(authored, source)
    assert patch["unit"] == ""
    assert Map.has_key?(patch, "min") and patch["min"] == nil
    refute Map.has_key?(patch, "max")
    refute Map.has_key?(patch, "step")

    looping = Map.put(@video, "loop", true)
    assert patch(looping, %{"block_id" => "t-video", "src" => @video["src"]})["loop"] == false
  end
end
