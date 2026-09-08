defmodule BarkparkWeb.Studio.PaperEditor.ContextualHistoryControlsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "Paper hosts expose initially disabled contextual history without taking native shortcuts" do
    html = editor(canvas_eligible: true)
    document = LazyHTML.from_fragment(html)

    for action <- ["undo", "redo"] do
      button = LazyHTML.query(document, "[data-paper-history-action='#{action}']")
      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.attribute(button, "disabled") == [""]
      assert LazyHTML.attribute(button, "phx-click") == []
      assert LazyHTML.attribute(button, "aria-keyshortcuts") == []
    end

    assert LazyHTML.attribute(LazyHTML.query(document, "[data-paper-history-status]"), "role") ==
             ["status"]
  end

  test "Beta and non-Paper documents do not expose Paper history controls" do
    for opts <- [[], [canvas_eligible: true, doc_type: "session"]] do
      refute editor(opts) =~ "data-paper-history-action"
    end
  end

  test "both hosts share themed history buttons and narrow touch targets" do
    css =
      File.read!(Path.expand("../../../../../priv/static/assets/bp-paper-editor-shell.css", __DIR__))

    assert css =~ ".bp-paper-contextual-panel button,\n.bp-paper-history-controls button {"
    assert css =~ ".bp-paper-history-controls button:focus-visible"
    assert css =~ "@media (max-width: 600px), (pointer: coarse)"
    assert css =~ ".bp-paper-history-controls button { min-width: 44px; min-height: 44px; }"
  end

  defp editor(opts) do
    render_component(
      &PaperEditor.paper_block_editor/1,
      Keyword.merge([slug: "history-controls", blocks: []], opts)
    )
  end
end
