defmodule BarkparkWeb.Studio.FocusVisibleCssTest do
  @moduledoc """
  task-494aa92fcb491f51: two keyboard tab stops showed no focus indicator
  (WCAG 2.4.7), only a text caret.

    * The desk search box is styled as a pane row: its input drops outline,
      border and shadow on focus. The ROW must show focus instead.
    * The canvas field label is its own editing surface (role=textbox,
      tabindex 0) and had no focus style in either paper-editor stylesheet.

  ExUnit has no layout engine, so this pins the source rules; the browser
  sweep in the PR measures the painted result and its contrast.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../lib/barkpark_web/layouts/root.html.heex", __DIR__)
  @shell Path.expand("../../../priv/static/assets/bp-paper-editor-shell.css", __DIR__)
  @bundle_css Path.expand("../../../priv/static/assets/bp-paper-editor.css", __DIR__)
  @src_css Path.expand("../../../assets/paper-editor/src/styles.css", __DIR__)

  # The declaration block of the first rule whose selector list is exactly `selector`.
  defp block(css, selector) do
    pattern = ~r/(?:^|[}\s])#{Regex.escape(selector)}\s*\{([^}]*)\}/

    case Regex.run(pattern, css, capture: :all_but_first) do
      [body] -> body
      _ -> nil
    end
  end

  test "the desk search row shows keyboard focus while its borderless input has it" do
    css = File.read!(@root)

    # The premise: the input itself suppresses every indicator.
    assert block(css, ".bp-desk-search-input:focus") =~ "outline: none"

    row = block(css, ".bp-desk-search:focus-within")
    assert row, "no .bp-desk-search:focus-within rule: focus on the search box is invisible"
    assert row =~ "var(--ring)"
  end

  test "the canvas field label shows keyboard focus in the shell, source and built stylesheets" do
    for path <- [@shell, @src_css, @bundle_css] do
      css = File.read!(path)

      rule =
        block(css, ~s(.bp-canvas-field-label[role="textbox"]:focus-visible)) ||
          block(css, ".bp-canvas-field-label[role=textbox]:focus-visible")

      assert rule, "#{Path.basename(path)}: the field label has no :focus-visible rule"
      assert rule =~ "outline"
      assert rule =~ "--paper-accent"
    end
  end
end
