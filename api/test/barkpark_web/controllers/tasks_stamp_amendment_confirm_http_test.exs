defmodule BarkparkWeb.TasksStampAmendmentConfirmHttpTest do
  @moduledoc """
  The second-eyes gate on the wire (task-e9c6aa61af536112): the amender's
  `met` is a 409 whose reason and message the bp CLI prints, and another
  worker's `confirm_amendment` over HTTP lets it through.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}

  @dataset "production"
  @token "amend-confirm-http-write"
  @old "the importer keeps every heading"
  @new "the importer keeps every heading and every table"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    {:ok, _} = Auth.create_token(@token, "amend-confirm", @dataset, ["write"], ws.id)

    {:ok, task} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "amend-confirm-http-#{System.unique_integer([:positive])}",
          "title" => "amend confirm over http",
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [%{"criterion" => @old, "met" => false, "evidence" => ""}]
          }
        },
        @dataset,
        scope
      )

    %{task: task, scope: scope}
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp stamp(conn, task, body), do: post_json(conn, "/v1/tasks/#{task.doc_id}/stamp", body)

  defp rev(task, scope) do
    {:ok, doc} = Content.get_document(task.doc_id, "task", @dataset, scope)
    doc.rev
  end

  test "the amender's met is a 409 naming the confirm command; a reviewer's confirm lets it through",
       %{conn: conn, task: task, scope: scope} do
    claim = post_json(conn, "/v1/tasks/#{task.doc_id}/claim", %{worker_id: "builder"})
    epoch = claim.resp_body |> Jason.decode!() |> get_in(["doc", "claim", "epoch"])

    amend =
      stamp(conn, task, %{
        worker_id: "builder",
        observed_epoch: epoch,
        criterion: 0,
        criterion_text: @old,
        amend: true,
        amended_criterion: @new,
        note: "the old wording missed tables"
      })

    assert amend.status == 200

    met = %{
      worker_id: "builder",
      observed_epoch: epoch,
      criterion: 0,
      criterion_text: @new,
      met: true,
      evidence: "PR #24999 merged to main as 9b76b4bfc9"
    }

    refused = stamp(conn, task, met)
    assert refused.status == 409
    body = Jason.decode!(refused.resp_body)
    assert body["reason"] == "amendment_unconfirmed:0"
    assert body["message"] =~ "--confirm-amendment"

    confirm =
      stamp(conn, task, %{
        worker_id: "reviewer",
        observed_epoch: 0,
        criterion: 0,
        "criterion-text": @new,
        "confirm-amendment": "true",
        note: "read it against the importer tests",
        "observed-rev": rev(task, scope)
      })

    assert confirm.status == 200

    assert stamp(conn, task, met).status == 200
  end
end
