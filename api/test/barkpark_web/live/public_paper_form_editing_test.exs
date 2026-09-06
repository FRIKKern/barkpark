defmodule BarkparkWeb.PublicPaperFormEditingTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}

  @dataset "production"

  setup %{conn: conn} do
    previous_canvas = System.get_env("BARKPARK_PAPER_CANVAS")
    System.put_env("BARKPARK_PAPER_CANVAS", "1")

    on_exit(fn ->
      if previous_canvas,
        do: System.put_env("BARKPARK_PAPER_CANVAS", previous_canvas),
        else: System.delete_env("BARKPARK_PAPER_CANVAS")
    end)

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    raw = "public-form-writer-#{System.unique_integer([:positive])}"
    {:ok, _token} = Auth.create_token(raw, "Public form editing", @dataset, ["read", "write"])
    %{conn: Plug.Test.init_test_session(conn, %{"api_token" => raw})}
  end

  for type <- ~w(form questionnaire) do
    test "public Paper edits and reloads " <> type <> " without stripping opaque metadata", %{
      conn: conn
    } do
      type = unquote(type)
      slug = "public-#{type}-editing-#{System.unique_integer([:positive])}"
      block = form_block(type)

      {:ok, _paper} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            dataset: @dataset,
            title: "#{type} editing",
            blocks: [block]
          })
        )

      {:ok, view, _html} = live(conn, "/papers/#{slug}")
      render_click(view, "paper-toggle-edit", %{})

      assert has_element?(view, ~s([data-test-id="paper-form-contextual-editor"]))
      assert has_element?(view, "#form-editor-#{block["id"]}")
      refute has_element?(view, ~s([data-test-id="paper-task-preview"]))

      request_id = Ecto.UUID.generate()

      params =
        block
        |> form_params()
        |> Map.put("question-0-prompt", "After #{type}")
        |> Map.put("question-0-option-1", "Updated")
        |> write_meta(view, request_id)

      render_hook(view, "paper-block-autosave", params)
      assert_reply(view, %{saved: true, request_id: ^request_id})

      saved = stored_block(slug)
      assert saved["type"] == type
      assert saved["unknown-block"] == %{"keep" => type}
      [question] = saved["questions"]
      assert question["prompt"] == "After #{type}"
      assert question["options"] == ["First", "Updated"]
      assert question["unknown-question"] == [type, 1]
      assert question["scale"] == %{"inactive" => true}

      no_op_request = Ecto.UUID.generate()

      render_hook(
        view,
        "paper-block-autosave",
        saved |> form_params() |> write_meta(view, no_op_request)
      )

      assert_reply(view, %{saved: true, request_id: ^no_op_request})
      assert stored_block(slug) == saved

      {:ok, reloaded, _html} = live(conn, "/papers/#{slug}")
      render_click(reloaded, "paper-toggle-edit", %{})
      assert has_element?(reloaded, "#form-editor-#{block["id"]}")
      assert has_element?(reloaded, ~s(input[name="question-0-prompt"][value="After #{type}"]))
      assert has_element?(reloaded, ~s(input[name="question-0-option-1"][value="Updated"]))
    end
  end

  defp form_block(type) do
    %{
      "id" => "#{type}-block",
      "type" => type,
      "kind" => if(type == "questionnaire", do: "questionnaire", else: "grill"),
      "unknown-block" => %{"keep" => type},
      "questions" => [
        %{
          "id" => "answer:primary",
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

  defp write_meta(params, view, request_id) do
    params
    |> Map.put("if_rev", socket_of(view).assigns.paper_rev)
    |> Map.put("request_id", request_id)
  end

  defp stored_block(slug), do: Content.get_public_paper(slug, @dataset).content["blocks"] |> hd()
  defp socket_of(view), do: :sys.get_state(view.pid).socket
end
