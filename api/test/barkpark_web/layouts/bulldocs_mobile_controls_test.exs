defmodule BarkparkWeb.Layouts.BulldocsMobileControlsTest do
  use ExUnit.Case, async: true

  @moduletag :bulldocs_mobile_controls

  @layout Path.expand(
            "../../../lib/barkpark_web/layouts/bulldocs.html.heex",
            __DIR__
          )

  test "paper view controls do not float over evidence on narrow screens" do
    src = File.read!(@layout)

    assert src =~ ~r/@media \(max-width: 720px\).*?\.bp-view-toggle \{.*?position: static;/s,
           "mobile reader controls must participate in page flow instead of covering paper text or figures"

    assert src =~
             ~r/@media \(max-width: 720px\).*?\.bp-view-toggle--email,\s*\.bp-mode-toggle \{.*?bottom: auto;/s,
           "the desktop vertical offsets must be cleared for the mobile control row"
  end
end
