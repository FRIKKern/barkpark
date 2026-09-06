defmodule BarkparkWeb.Studio.PaperEditor.TerminalContextualEditorTest do
  use ExUnit.Case, async: true

  @editor_shell_css Path.expand(
                      "../../../../../priv/static/assets/bp-paper-editor-shell.css",
                      __DIR__
                    )

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

  test "Terminal is a contextual boundary with one canonical frame and scoped child run" do
    terminal = terminal([paragraph("body", "Inside terminal")])

    refute PaperCanvas.canvas?(terminal)
    assert PaperCanvas.partition_runs([terminal]) == [{:block, terminal}]

    tree = terminal |> render_fields(canvas_enabled: true) |> LazyHTML.from_fragment()
    boundary = LazyHTML.query(tree, "#paper-terminal-boundary-terminal")

    assert LazyHTML.attribute(boundary, "phx-hook") == ["BarkparkTerminalBoundary"]
    assert LazyHTML.attribute(boundary, "data-paper-terminal-supported") == ["true"]
    assert LazyHTML.attribute(boundary, "data-paper-terminal-rev") == ["7"]

    assert Enum.count(LazyHTML.query(tree, ".bp-term")) == 1
    assert Enum.count(LazyHTML.query(tree, ".bp-term__bar")) == 1
    assert Enum.count(LazyHTML.query(tree, ".bp-term__body")) == 1
    assert Enum.count(LazyHTML.query(tree, ".bp-term__foot")) == 1
    assert LazyHTML.text(LazyHTML.query(tree, ".bp-term__title")) =~ "Shell"
    assert LazyHTML.text(LazyHTML.query(tree, ".bp-term__foot")) =~ "q quit"

    run = LazyHTML.query(tree, "[data-test-id='paper-canvas-run']")
    assert LazyHTML.attribute(run, "data-paper-container-kind") == ["terminal"]
    assert LazyHTML.attribute(run, "data-paper-container-id") == ["terminal"]
    assert LazyHTML.attribute(run, "data-paper-container-run") == ["0"]
    assert LazyHTML.attribute(run, "data-paper-container-row-id") == []

    assert LazyHTML.attribute(run, "id") == [
             "paper-canvas-" <>
               PaperCanvas.run_id(PaperCanvas.terminal_run_slug("paper", "terminal"), 0)
           ]
  end

  test "native closed configuration uses exact reader-effective form values" do
    block =
      terminal([paragraph("body", "Inside")])
      |> Map.merge(%{"title" => 7, "footer" => nil, "live" => "live"})

    tree = block |> render_fields() |> LazyHTML.from_fragment()
    controls = LazyHTML.query(tree, "#terminal-controls-terminal")

    assert LazyHTML.attribute(controls, "open") == []
    assert LazyHTML.text(LazyHTML.query(controls, "summary")) =~ "Configure terminal"
    assert input_value(controls, "title") == ["7"]
    assert input_value(controls, "footer") == [""]
    assert input_value(controls, "live") == ["false", "true"]

    assert LazyHTML.attribute(LazyHTML.query(controls, "input[type='checkbox']"), "checked") == [
             ""
           ]

    assert Enum.empty?(LazyHTML.query(tree, "form form"))
  end

  test "empty Terminal exposes only the explicit fenced paragraph action" do
    tree = terminal([]) |> render_fields() |> LazyHTML.from_fragment()
    form = LazyHTML.query(tree, "[data-test-id='paper-terminal-structure-editor']")

    assert input_value(form, "block_id") == ["terminal"]
    assert input_value(form, "terminal-child-count") == ["0"]

    [new_id] = input_value(form, "terminal-new-child-id")
    assert is_binary(new_id) and String.trim(new_id) != ""

    assert LazyHTML.attribute(LazyHTML.query(form, "button"), "name") == ["terminal-action"]
    assert LazyHTML.attribute(LazyHTML.query(form, "button"), "value") == ["add"]
    assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-canvas-run']"))
  end

  test "nonempty Terminal keeps acknowledgement identity but omits the empty-only action" do
    tree = terminal([paragraph("body", "Inside")]) |> render_fields() |> LazyHTML.from_fragment()
    form = LazyHTML.query(tree, "[data-test-id='paper-terminal-structure-editor']")

    assert input_value(form, "terminal-child-count") == ["1"]
    assert input_value(form, "terminal-child-0-id") == ["body"]
    assert Enum.empty?(LazyHTML.query(form, "button[name='terminal-action']"))
  end

  test "generic Beta recursively edits children without a parent canvas" do
    tree =
      terminal([paragraph("body", "Inside")])
      |> render_fields(canvas_enabled: false)
      |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(tree, "#paper-ed-body")) == 1
    assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-canvas-run']"))
    assert Enum.count(LazyHTML.query(tree, ".bp-term")) == 1
  end

  test "legacy malformed dual and identity-unsafe Terminals remain one full reader preview" do
    cases = [
      {Map.put(terminal([]), "blocks", [paragraph("shadow", "Shadow")]), true},
      {Map.put(terminal([]), "children", "opaque"), true},
      {terminal([Map.delete(paragraph("body", "Visible"), "id")]), true},
      {terminal([paragraph("body", "Visible")]), false}
    ]

    for {block, tree_identity_safe} <- cases do
      tree =
        block
        |> render_fields(canvas_enabled: true, tree_identity_safe: tree_identity_safe)
        |> LazyHTML.from_fragment()

      assert Enum.count(LazyHTML.query(tree, ".bp-term")) == 1
      assert Enum.count(LazyHTML.query(tree, ".bp-term__body")) == 1
      assert Enum.count(LazyHTML.query(tree, "[data-test-id='paper-terminal-readonly']")) == 1

      assert LazyHTML.attribute(
               LazyHTML.query(tree, "#paper-terminal-boundary-terminal"),
               "data-paper-terminal-supported"
             ) == ["false"]

      assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-terminal-editor']"))
      assert Enum.empty?(LazyHTML.query(tree, "[data-test-id='paper-canvas-run']"))
    end
  end

  test "public form state shares strict body and reader-effective chrome semantics" do
    assert Blocks.terminal_form_state(
             terminal([])
             |> Map.merge(%{"title" => 9, "footer" => %{}, "live" => "true"})
           ) ==
             {:ok, %{title: "9", footer: "", live: true, children: []}}

    assert Blocks.terminal_form_state(Map.put(terminal([]), "blocks", [])) ==
             {:error, :malformed_terminal}
  end

  test "contextual Terminal wrappers preserve reader margin collapse between blocks" do
    css = File.read!(@editor_shell_css)

    assert css =~
             ~S|.bp-paper-edit-block[data-block-type="terminal"] + .bp-paper-edit-block[data-block-type="terminal"] > .bp-paper-contextual-editor > [data-paper-terminal-editor-frame] {
  margin-top: 0;
}|

    assert css =~
             ~S|.bp-paper-edit-block[data-block-type="terminal"] + .bp-paper-edit-block[data-block-type="terminal"] > .bp-paper-contextual-editor > [data-test-id="paper-terminal-readonly"] > .bp-term {
  margin-top: 0;
}|

    assert css =~
             ~S|.bp-paper-edit-block[data-block-type="terminal"] + .bp-paper-edit-canvas .bp-paper-editor-body .ProseMirror > p:first-child {
  margin-top: 0;
}|

    assert css =~
             ~S|:is(.bp-section__cell, .bp-cols__c) > .bp-paper-contextual-editor:first-child > [data-paper-terminal-editor-frame] {
  margin-top: 0;
}|
  end

  defp input_value(tree, name),
    do: tree |> LazyHTML.query(~s([name="#{name}"])) |> LazyHTML.attribute("value")

  defp render_fields(block, opts \\ []) do
    render_component(
      &PaperEditor.paper_block_fields/1,
      Keyword.merge(
        [
          block: block,
          root_slug: "paper",
          paper_rev: 7,
          doc_key: "production:paper:paper"
        ],
        opts
      )
    )
  end

  defp terminal(children) do
    %{
      "id" => "terminal",
      "type" => "terminal",
      "title" => "Shell",
      "footer" => "q quit",
      "live" => true,
      "children" => children
    }
  end

  defp paragraph(id, text),
    do: %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }
end
