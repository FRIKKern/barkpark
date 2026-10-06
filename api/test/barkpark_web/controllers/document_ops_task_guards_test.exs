defmodule BarkparkWeb.DocumentOpsTaskGuardsTest do
  @moduledoc """
  Owner ruling #35, item 4: `POST /v1/data/doc/:ds/:type/:id/ops` runs the
  mutate door's task guards.

  A block op re-projects every bound block (`fieldName`) into `content` and
  writes through `upsert_document/4`. Before this, nothing on that path ran
  the claim fence, the close fence or the plugin mutate-door fences, so one
  `append-block` carrying `fieldName: "claim"` or `"lifecycle_status"` forged
  the task's claim or closed it.

  The arms:

    * a forged claim answers the same 422 `validation_failed` the mutate door
      gives, keyed `claim`, and nothing is written;
    * a forged terminal `lifecycle_status` answers the mutate door's close
      fence refusal, keyed `lifecycle_status`;
    * a forged `disposition` answers the Tasks plugin fence's refusal;
    * an ordinary paragraph op on a task, and on a post, still succeeds.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, LabelFixtures}

  @dataset "test"
  @token "barkpark-test-ops-task-guards"

  setup do
    ws = Barkpark.TenancyFixtures.default_workspace_id!()
    {:ok, _} = Auth.create_token(@token, "ops-task-guards", @dataset, ["read", "write"], ws)

    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @dataset
    )

    LabelFixtures.register_tags!(@dataset)
    :ok
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp as(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  @claim %{"worker" => "honest-worker", "epoch" => 1}

  # A published, claimed task — the shape `bp task claim` leaves behind.
  defp claimed_task!(id) do
    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "in_progress",
        "priority" => 2,
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" =>
          "A deliberately long description so the label spine is satisfied and " <>
            "the only variable under test is the ops door's guards.",
        "acceptance_criteria" => [%{"criterion" => "the guard holds", "met" => false}],
        "claim" => @claim
      }
      |> Map.merge(LabelFixtures.weighted_labels())

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => id, "title" => "probe #{id}", "content" => content},
        @dataset
      )

    {:ok, doc} = Content.publish_document(id, "task", @dataset)
    doc
  end

  defp raw(id, type) do
    {:ok, doc} = Content.get_document(id, type, @dataset)
    doc
  end

  defp op!(type, id, rev, op) do
    scoped_conn()
    |> as()
    |> post(
      "/v1/data/doc/#{@dataset}/#{type}/#{id}/ops",
      Jason.encode!(%{"op" => op, "ifRev" => rev})
    )
  end

  defp bound_block(field, value) do
    %{
      "op" => "append-block",
      "block" => %{
        "type" => "paragraph",
        "fieldName" => field,
        "value" => value,
        "content" => [%{"type" => "text", "value" => "x"}]
      }
    }
  end

  defp paragraph_op(text) do
    %{
      "op" => "append-block",
      "block" => %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
    }
  end

  defp refusal(resp) do
    assert resp.status == 422, "expected 422, got #{resp.status} #{resp.resp_body}"
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "validation_failed", resp.resp_body
    error["details"]
  end

  defp no_draft_written(id) do
    assert {:error, :not_found} = Content.get_document("drafts." <> id, "task", @dataset)
  end

  test "a batch carrying a block bound to `claim` is refused whole" do
    id = uniq("ops-claim-batch")
    task = claimed_task!(id)

    details =
      scoped_conn()
      |> as()
      |> post(
        "/v1/data/doc/#{@dataset}/task/#{id}/ops",
        Jason.encode!(%{
          "ops" => [
            paragraph_op("harmless"),
            bound_block("claim", %{"worker" => "attacker", "epoch" => 99})
          ],
          "ifRev" => task.rev
        })
      )
      |> refusal()

    assert [_message] = details["claim"]
    no_draft_written(id)
  end

  test "a block bound to `claim` cannot substitute the claim" do
    id = uniq("ops-claim")
    task = claimed_task!(id)

    details =
      op!("task", id, task.rev, bound_block("claim", %{"worker" => "attacker", "epoch" => 99}))
      |> refusal()

    assert [message] = details["claim"]
    assert message =~ "honest-worker"
    no_draft_written(id)
    assert raw(id, "task").content["claim"] == @claim
  end

  test "a block bound to `claim` cannot drop the claim" do
    id = uniq("ops-claim-drop")
    task = claimed_task!(id)

    details = op!("task", id, task.rev, bound_block("claim", nil)) |> refusal()
    assert is_list(details["claim"])
    no_draft_written(id)
  end

  # `blocked` is in the mutate door's terminal set and the writer's own
  # transition table lets it through, so only the close fence stands here.
  test "a block bound to `lifecycle_status` cannot move the task to a terminal state" do
    id = uniq("ops-close")
    task = claimed_task!(id)

    details = op!("task", id, task.rev, bound_block("lifecycle_status", "blocked")) |> refusal()

    assert [message] = details["lifecycle_status"]
    assert message =~ "bp task close"
    no_draft_written(id)
    assert raw(id, "task").content["lifecycle_status"] == "in_progress"
  end

  # `done` was already refused by the writer, but the door answered a bare
  # 422 `invalid_op` with no field. It now carries the per-field details.
  test "a forged `done` names the field instead of a bare invalid_op" do
    id = uniq("ops-done")
    task = claimed_task!(id)

    details = op!("task", id, task.rev, bound_block("lifecycle_status", "done")) |> refusal()
    assert [_message] = details["lifecycle_status"]
    no_draft_written(id)
  end

  test "a block bound to `disposition` meets the Tasks plugin fence" do
    id = uniq("ops-disposition")
    task = claimed_task!(id)

    details = op!("task", id, task.rev, bound_block("disposition", "parked")) |> refusal()
    assert is_map(details) and map_size(details) > 0
    no_draft_written(id)
  end

  test "an ordinary paragraph op on a claimed task still lands" do
    id = uniq("ops-body")
    task = claimed_task!(id)

    resp = op!("task", id, task.rev, paragraph_op("notes from the worker"))
    assert resp.status == 200, resp.resp_body

    {:ok, draft} = Content.get_document("drafts." <> id, "task", @dataset)
    assert draft.content["claim"] == @claim
    assert draft.content["lifecycle_status"] == "in_progress"
  end

  test "an ordinary op on a post is untouched by the task guards" do
    id = uniq("ops-post")

    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => id, "title" => "Ops target", "content" => %{}},
        @dataset
      )

    resp = op!("post", id, doc.rev, paragraph_op("second"))
    assert resp.status == 200, resp.resp_body
  end
end
