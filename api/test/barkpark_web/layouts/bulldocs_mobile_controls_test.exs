defmodule BarkparkWeb.Layouts.BulldocsMobileControlsTest do
  use ExUnit.Case, async: true

  @moduletag :bulldocs_mobile_controls

  @layout Path.expand(
            "../../../lib/barkpark_web/layouts/bulldocs.html.heex",
            __DIR__
          )

  test "paper view controls share one normal-flow utility row" do
    src = File.read!(@layout)

    assert src =~
             ~s|<div class="bp-view-controls" role="group" aria-label="Paper view controls">|

    assert src =~ ~r/\.bp-view-controls \{.*?display: flex;.*?flex-wrap: wrap;/s

    refute src =~ ~r/\.bp-view-toggle \{[^}]*position:\s*fixed;/s,
           "reader controls must never cover paper text or evidence"

    assert src =~
             ~r/@media \(max-width: 720px\).*?\.bp-view-controls \{.*?width: calc\(100% - 32px\);/s,
           "the grouped controls must fit the narrow viewport"
  end

  test "mobile evidence uses the viewport without cropping images" do
    src = File.read!(@layout)

    assert src =~ ~r/@media \(max-width: 720px\).*?--bp-evidence-width: calc\(100vw - 32px\);/s

    assert src =~
             ~r/@media \(max-width: 720px\).*?figure > \.bp-cols img \{.*?width: 100%;.*?height: auto;.*?max-height: none;/s
  end
end
