defmodule BarkparkWeb.SheetGrid.SheetHeaderNarrowLayoutTest do
  @moduledoc """
  task-5d4f085dff4dd8ea: at phone width the sheet editor's six text actions sat
  in a flex-end row with visible overflow and spilled LEFT — Rename and Publish
  off-screen, the rest painted over the title. The paper header's narrow rule
  is a `@container panel` query, and `.editor-panel.sheet-editor` opts out of
  container queries, so the sheet never got it. Its own rule keys on the width
  bucket. This reads the shipped stylesheet; the layout is checked in a browser.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)

  test "below the wide bucket the sheet header is a two-row grid whose actions wrap" do
    css = File.read!(@root)

    header =
      ~S|html:not([data-width-bucket="wide"]) .editor-panel.sheet-editor > .editor-header {|

    actions =
      ~S|html:not([data-width-bucket="wide"]) .editor-panel.sheet-editor > .editor-header > div:last-child {|

    [_, header_body] = Regex.run(~r/#{Regex.escape(header)}([^}]*)\}/, css)
    assert header_body =~ "display: grid"
    assert header_body =~ "grid-template-columns: minmax(0, 1fr)"
    assert header_body =~ "height: auto"

    [_, actions_body] = Regex.run(~r/#{Regex.escape(actions)}([^}]*)\}/, css)
    assert actions_body =~ "flex-wrap: wrap"

    # Still opted out of container queries: the bucket rule is the only reach.
    assert css =~ ".editor-panel.sheet-editor { container-type: normal; }"
  end
end
