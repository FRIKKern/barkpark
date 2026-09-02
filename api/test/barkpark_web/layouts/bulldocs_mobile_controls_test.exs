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

    # This used to pin a literal `calc(100vw - 32px)` here. That literal was
    # written for a 16px gutter while `padding-inline: 20px`, declared later in
    # the sheet, actually won — so the band edge and the prose edge were 4px
    # apart by construction. The band now derives its width from the ONE gutter
    # token, which is what makes them impossible to drift apart; the concrete
    # numbers come from the ladder pinned immediately below.
    assert src =~
             ~r/@media \(max-width: 767px\).*?--bp-evidence-width: calc\(100vw - 2 \* var\(--paper-gutter\)\);/s,
           "the evidence band must read --paper-gutter, never its own literal"

    # The ladder rungs, so this test still pins real widths: 24px of gutter at
    # the tablet step and 16px at the phone step, i.e. a band of 100vw minus
    # 48px and minus 32px respectively.
    assert src =~ ~r/@media \(max-width: 767px\).*?--paper-gutter: 24px;/s,
           "the tablet rung of the gutter ladder is gone"

    assert src =~ ~r/@media \(max-width: 479px\).*?--paper-gutter: 16px;/s,
           "the phone rung of the gutter ladder is gone"

    assert src =~
             ~r/@media \(max-width: 720px\).*?figure > \.bp-cols img \{.*?width: 100%;.*?height: auto;.*?max-height: none;/s
  end
end
