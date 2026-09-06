defmodule BarkparkWeb.Studio.StudioBetaFormEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"
  @doc_type "beta_form_editing"

  setup do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @doc_type,
          "title" => "Beta form editing",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    blocks = [form_block("form"), form_block("questionnaire")]
    id = "beta-form-#{System.unique_integer([:positive])}"

    {:ok, doc} =
      Content.create_document(
        @doc_type,
        %{"doc_id" => id, "title" => "Forms", "content" => %{"blocks" => blocks}},
        @dataset
      )

    {:ok, doc: doc}
  end

  test "generic Beta edits both form aliases, rejects a stale base, and reloads opaque metadata",
       %{conn: conn, doc: doc} do
    raw = "beta-form-writer-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Beta form editing", @dataset, ["read", "write"])
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    path = scoped_studio("/d/#{@dataset}/studio/#{@doc_type}/#{doc.doc_id}")
    {:ok, view, _html} = live(conn, path)

    view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(view, ~s([data-test-id="studio-doc-beta-editor"]))

    assert view
           |> render()
           |> LazyHTML.from_document()
           |> LazyHTML.query(~s([data-test-id="paper-form-contextual-editor"]))
           |> Enum.count() == 2

    assert has_element?(view, "#form-editor-form-block")
    assert has_element?(view, "#form-editor-questionnaire-block")
    refute has_element?(view, ~s([data-test-id="paper-task-preview"]))

    initial_rev = socket_of(view).assigns.editor_doc.rev
    form = stored_block(doc.doc_id, "form-block")
    form_request = Ecto.UUID.generate()

    form_params =
      form
      |> form_params()
      |> Map.put("question-0-prompt", "After form")
      |> Map.put("question-0-option-1", "Updated form")
      |> write_meta(view, form_request)

    render_hook(view, "paper-block-autosave", form_params)
    assert_reply(view, %{saved: true, request_id: ^form_request, rev: committed_rev})

    saved_form = stored_block(doc.doc_id, "form-block")
    assert_form_saved(saved_form, "form", "After form", "Updated form")

    questionnaire = stored_block(doc.doc_id, "questionnaire-block")
    stale_request = Ecto.UUID.generate()

    stale_params =
      questionnaire
      |> form_params()
      |> Map.put("question-0-prompt", "Stale questionnaire")
      |> Map.put("if_rev", initial_rev)
      |> Map.put("request_id", stale_request)

    render_hook(view, "paper-block-autosave", stale_params)

    assert_reply(view, %{
      saved: false,
      request_id: ^stale_request,
      conflict: true,
      current_rev: ^committed_rev
    })

    unchanged_questionnaire = stored_block(doc.doc_id, "questionnaire-block")
    assert hd(unchanged_questionnaire["questions"])["prompt"] == "Before questionnaire"

    questionnaire_request = Ecto.UUID.generate()

    questionnaire_params =
      unchanged_questionnaire
      |> form_params()
      |> Map.put("question-0-prompt", "After questionnaire")
      |> Map.put("question-0-option-1", "Updated questionnaire")
      |> write_meta(view, questionnaire_request)

    render_hook(view, "paper-block-autosave", questionnaire_params)
    assert_reply(view, %{saved: true, request_id: ^questionnaire_request})

    saved_questionnaire = stored_block(doc.doc_id, "questionnaire-block")

    assert_form_saved(
      saved_questionnaire,
      "questionnaire",
      "After questionnaire",
      "Updated questionnaire"
    )

    for saved <- [saved_form, saved_questionnaire] do
      no_op_request = Ecto.UUID.generate()

      render_hook(
        view,
        "paper-block-autosave",
        saved |> form_params() |> write_meta(view, no_op_request)
      )

      assert_reply(view, %{saved: true, request_id: ^no_op_request})
      assert stored_block(doc.doc_id, saved["id"]) == saved
    end

    {:ok, reloaded, _html} = live(conn, path)
    reloaded |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert has_element?(reloaded, "#form-editor-form-block")
    assert has_element?(reloaded, "#form-editor-questionnaire-block")

    assert has_element?(
             reloaded,
             ~s(#form-editor-form-block input[name="question-0-prompt"][value="After form"])
           )

    assert has_element?(
             reloaded,
             ~s(#form-editor-questionnaire-block input[name="question-0-prompt"][value="After questionnaire"])
           )
  end

  defp form_block(type) do
    %{
      "id" => "#{type}-block",
      "type" => type,
      "kind" => if(type == "questionnaire", do: "questionnaire", else: "grill"),
      "unknown-block" => %{"keep" => type},
      "questions" => [
        %{
          "id" => "#{type}:answer",
          "prompt" => "Before #{type}",
          "type" => "single",
          "rationale" => "Keep rationale",
          "recommendation" => "Keep recommendation",
          "options" => ["First", "Second"],
          "scale" => %{"inactive" => true},
          "unknown-question" => [type, 1]
        }
      ]
    }
  end

  defp form_params(block) do
    [question] = block["questions"]

    %{
      "block_id" => block["id"],
      "kind" => block["kind"],
      "question-count" => "1",
      "question-0-original-id" => question["id"],
      "question-0-id" => question["id"],
      "question-0-prompt" => question["prompt"],
      "question-0-type" => question["type"],
      "question-0-rationale" => question["rationale"],
      "question-0-recommendation" => question["recommendation"],
      "question-0-option-count" => "2",
      "question-0-option-0" => Enum.at(question["options"], 0),
      "question-0-option-1" => Enum.at(question["options"], 1)
    }
  end

  defp assert_form_saved(block, type, prompt, second_option) do
    assert block["type"] == type
    assert block["unknown-block"] == %{"keep" => type}
    [question] = block["questions"]
    assert question["prompt"] == prompt
    assert question["options"] == ["First", second_option]
    assert question["unknown-question"] == [type, 1]
    assert question["scale"] == %{"inactive" => true}
  end

  defp write_meta(params, view, request_id) do
    params
    |> Map.put("if_rev", socket_of(view).assigns.editor_doc.rev)
    |> Map.put("request_id", request_id)
  end

  defp stored_block(doc_id, block_id) do
    {:ok, doc} = Content.get_document(doc_id, @doc_type, @dataset)
    Enum.find(doc.content["blocks"], &(&1["id"] == block_id))
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
