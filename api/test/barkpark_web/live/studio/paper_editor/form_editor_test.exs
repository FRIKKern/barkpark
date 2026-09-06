defmodule BarkparkWeb.Studio.PaperEditor.FormEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "Form and Questionnaire are creatable from the block menu" do
    tree =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: [],
        canvas_eligible: true
      )
      |> LazyHTML.from_fragment()

    assert tree |> LazyHTML.query("option[value='form']") |> LazyHTML.text() == "Form"

    assert tree |> LazyHTML.query("option[value='questionnaire']") |> LazyHTML.text() ==
             "Questionnaire"
  end

  test "canvas-enabled Paper hosts route both aliases to one contextual boundary without duplicate fleet paint" do
    for type <- ["form", "questionnaire"] do
      html =
        render_component(&PaperEditor.paper_block_editor/1,
          slug: "paper",
          blocks: [%{"id" => type, "type" => type, "questions" => []}],
          canvas_eligible: true,
          paper_rev: 3
        )

      assert html =~ ~s(data-block-type="#{type}")
      assert html =~ ~s(data-test-id="paper-form-contextual-editor")
      assert html =~ ~s(data-test-id="paper-form-editor")
      refute html =~ ~s(data-test-id="paper-task-preview")
      refute html =~ ~s(phx-hook="BarkparkPaperCanvas")
    end
  end

  test "reader preview stays visible beside one in-flow authored configuration form" do
    html = render_component(&PaperEditor.paper_block_fields/1, block: authored_form())
    tree = LazyHTML.from_fragment(html)

    assert html =~ ~s(class="bp-form bp-form-grill")
    assert html =~ "Choose a route"
    assert html =~ "Carefully"
    assert html =~ "Start small"
    assert html =~ ~s(class="bp-paper-contextual-controls bp-paper-contextual-controls--form")
    assert Enum.empty?(LazyHTML.query(tree, "form form"))

    assert LazyHTML.attribute(
             LazyHTML.query(tree, "form[data-test-id='paper-form-editor']"),
             "id"
           ) == ["form-editor-form"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='question-count']"), "value") == [
             "2"
           ]

    assert LazyHTML.attribute(
             LazyHTML.query(tree, "input[name='question-0-original-id']"),
             "value"
           ) == ["route:choice"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='question-0-id']"), "value") == [
             "route:choice"
           ]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='question-0-prompt']"), "value") ==
             ["Choose a route"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='question-0-rationale']"), "value") ==
             ["Carefully"]

    assert LazyHTML.attribute(
             LazyHTML.query(tree, "input[name='question-0-recommendation']"),
             "value"
           ) == ["Start small"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "button[name='question-action']"), "value") ==
             [
               "up:route:choice",
               "down:route:choice",
               "remove:route:choice",
               "up:confidence",
               "down:confidence",
               "remove:confidence",
               "add"
             ]
  end

  test "choice options and scale bounds use labelled inline controls with exact stable actions" do
    html = render_component(&PaperEditor.paper_block_fields/1, block: authored_form())
    tree = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(
             LazyHTML.query(tree, "input[name='question-0-option-count']"),
             "value"
           ) == ["2"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='question-0-option-0']"), "value") ==
             ["Walk"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='question-0-option-1']"), "value") ==
             ["Cycle"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "button[name='option-action']"), "value") == [
             "up:route:choice:0",
             "down:route:choice:0",
             "remove:route:choice:0",
             "up:route:choice:1",
             "down:route:choice:1",
             "remove:route:choice:1",
             "add:route:choice"
           ]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='question-1-scale-min']"), "value") ==
             ["1"]

    assert LazyHTML.attribute(LazyHTML.query(tree, "input[name='question-1-scale-max']"), "value") ==
             ["7"]

    assert Enum.empty?(LazyHTML.query(tree, "textarea[name$='json']"))
  end

  test "scale controls emit the reader defaults when authored bounds are absent or nil" do
    for question <- [
          %{"id" => "confidence", "type" => "scale"},
          %{
            "id" => "confidence",
            "type" => "scale",
            "scale" => %{"min" => nil, "max" => nil}
          }
        ] do
      tree =
        render_component(&PaperEditor.paper_block_fields/1,
          block: %{"id" => "form", "type" => "form", "questions" => [question]}
        )
        |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(
               LazyHTML.query(tree, "input[name='question-0-scale-min']"),
               "value"
             ) == ["1"]

      assert LazyHTML.attribute(
               LazyHTML.query(tree, "input[name='question-0-scale-max']"),
               "value"
             ) == ["5"]
    end
  end

  test "scale controls preserve exact signed and zero-padded integer wires" do
    tree =
      render_component(&PaperEditor.paper_block_fields/1,
        block: %{
          "id" => "form",
          "type" => "form",
          "questions" => [
            %{
              "id" => "confidence",
              "type" => "scale",
              "scale" => %{"min" => "01", "max" => "+5"}
            }
          ]
        }
      )
      |> LazyHTML.from_fragment()

    for {name, value} <- [
          {"question-0-scale-min", "01"},
          {"question-0-scale-max", "+5"}
        ] do
      input = LazyHTML.query(tree, "input[name='#{name}']")
      assert LazyHTML.attribute(input, "type") == ["text"]
      assert LazyHTML.attribute(input, "inputmode") == ["numeric"]
      assert LazyHTML.attribute(input, "pattern") == ["([+]|-)?[0-9]+"]
      assert LazyHTML.attribute(input, "value") == [value]
    end
  end

  test "Questionnaire alias and unknown binary kind/type stay selected without normalization" do
    block = %{
      "id" => "survey",
      "type" => "questionnaire",
      "kind" => "legacy-kind",
      "questions" => [
        %{"id" => "legacy:answer", "prompt" => "Legacy", "type" => "legacy-type"}
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, block: block)
    tree = LazyHTML.from_fragment(html)

    assert html =~ ~s(class="bp-form bp-form-grill")

    assert LazyHTML.attribute(
             LazyHTML.query(tree, "select[name='kind'] option[selected]"),
             "value"
           ) == ["legacy-kind"]

    assert LazyHTML.attribute(
             LazyHTML.query(tree, "select[name='question-0-type'] option[selected]"),
             "value"
           ) == ["legacy-type"]
  end

  test "missing collections initialize and questionnaire defaults its display kind" do
    for block <- [
          %{"id" => "form", "type" => "form"},
          %{"id" => "form", "type" => "form", "questions" => nil},
          %{"id" => "survey", "type" => "questionnaire"}
        ] do
      html = render_component(&PaperEditor.paper_block_fields/1, block: block)
      tree = LazyHTML.from_fragment(html)
      assert html =~ ~s(name="question-count" value="0")

      assert LazyHTML.attribute(
               LazyHTML.query(tree, "form[data-test-id='paper-form-editor']"),
               "id"
             ) == ["form-editor-#{block["id"]}"]

      if block["type"] == "questionnaire" do
        assert LazyHTML.attribute(
                 LazyHTML.query(tree, "select[name='kind'] option[selected]"),
                 "value"
               ) == ["questionnaire"]
      end
    end
  end

  test "an explicit nil kind on the Questionnaire alias keeps the renderer's grill semantics" do
    block = %{
      "id" => "survey",
      "type" => "questionnaire",
      "kind" => nil,
      "questions" => []
    }

    html = render_component(&PaperEditor.paper_block_fields/1, block: block)
    tree = LazyHTML.from_fragment(html)

    assert html =~ ~s(class="bp-form bp-form-grill")

    assert LazyHTML.attribute(
             LazyHTML.query(tree, "select[name='kind'] option[selected]"),
             "value"
           ) == [
             "grill"
           ]
  end

  test "active malformed shapes and ambiguous answer names remain canonical read-only previews" do
    malformed = [
      "legacy",
      [%{"id" => "same", "prompt" => "One"}, %{"id" => "same", "prompt" => "Two"}],
      [%{"id" => "  ", "prompt" => "Blank"}],
      [%{"id" => "choice", "prompt" => "Choice", "type" => "single", "options" => "legacy"}],
      [%{"id" => "scale", "prompt" => "Scale", "type" => "scale", "scale" => nil}],
      [%{"id" => "scale", "prompt" => "Scale", "type" => "scale", "scale" => "legacy"}],
      [%{"id" => "scale", "prompt" => "Scale", "type" => "scale", "scale" => %{"min" => "1.5"}}],
      [%{"id" => "text", "prompt" => %{"legacy" => true}, "type" => "text"}]
    ]

    for questions <- malformed do
      html =
        render_component(&PaperEditor.paper_block_fields/1,
          block: %{"id" => "form", "type" => "form", "questions" => questions}
        )

      assert html =~ ~s(data-test-id="paper-form-preview")
      assert html =~ "original content is preserved"
      refute html =~ ~s(data-test-id="paper-form-editor")
      refute html =~ ~s(name="question-action")
      refute html =~ ~s(name="option-action")
    end
  end

  test "inactive malformed options and scale metadata remain editable and opaque" do
    block = %{
      "id" => "form",
      "type" => "form",
      "questions" => [
        %{
          "id" => "answer",
          "prompt" => "Answer",
          "type" => "text",
          "options" => "opaque",
          "scale" => false
        }
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, block: block)
    assert html =~ ~s(data-test-id="paper-form-editor")
    refute html =~ ~s(name="question-0-option-count")
    refute html =~ ~s(name="question-0-scale-min")
  end

  defp authored_form do
    %{
      "id" => "form",
      "type" => "form",
      "kind" => "grill",
      "questions" => [
        %{
          "id" => "route:choice",
          "prompt" => "Choose a route",
          "type" => "single",
          "rationale" => "Carefully",
          "recommendation" => "Start small",
          "options" => ["Walk", "Cycle"]
        },
        %{
          "id" => "confidence",
          "prompt" => "Confidence",
          "type" => "scale",
          "scale" => %{"min" => 1, "max" => "7"}
        }
      ]
    }
  end
end
