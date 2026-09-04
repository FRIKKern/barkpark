defmodule BarkparkWeb.MutateTaskPublishedFirstTest do
  @moduledoc """
  task-b9c618482e688500, C0 — the whole exchange, end to end through the two
  HTTP doors that used to disagree.

  The live measurement this pins (guerrilla 2026-09-02, cli-w14):

      GET  /v1/tasks/<id>                 -> rev R  (published-first read)
      POST /v1/data/mutate/<ds> ifRev R   -> 412    (actual = the TWIN's rev)
      POST /v1/data/mutate/<ds> ifRev T   -> 200, results[0].id = drafts.<id>
      GET  /v1/tasks/<id>                 -> UNCHANGED

  A success envelope for a write nothing reads. The tests below run exactly
  that sequence and assert the repaired shape: the rev the task API serves is
  ACCEPTED, the receipt names the bare id, and the follow-up
  `GET /v1/tasks/<id>` reflects the patch. The twin case asserts the other
  half of the invariant — a patch that cannot land honestly is REFUSED with a
  reason naming `drafts.<id>`, never a 200 onto the twin.

  `scoped_conn/0` (the suite's own per-test rate-limit scope) is used for every
  request: this file makes several calls per test against an ip-keyed limiter.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, LabelFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Content.DraftId

  @token "barkpark-test-mutate-task-pf"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-mutate-task-pf", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp authed do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task_content(extra) do
    %{"kind" => "task", "lifecycle_status" => "open"}
    |> Map.merge(extra)
    |> LabelFixtures.with_registered_labels(@dataset)
  end

  defp mk_published_task!(scope, extra) do
    id = uniq("mtpf")

    {:ok, _} =
      Content.create_document(
        "task",
        %{"doc_id" => id, "title" => id, "content" => task_content(extra)},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(id, "task", @dataset, scope)
    id
  end

  # The read door: exactly what an agent runs before composing its patch.
  defp get_task(id) do
    resp = get(authed(), "/v1/tasks/#{id}")
    assert resp.status == 200, "GET /v1/tasks/#{id} => #{resp.status}: #{resp.resp_body}"
    Jason.decode!(resp.resp_body)["doc"]
  end

  defp post_patch(id, set_fields, if_rev) do
    patch =
      %{"id" => id, "type" => "task", "set" => set_fields}
      |> then(fn p -> if if_rev, do: Map.put(p, "ifRevisionID", if_rev), else: p end)

    post(
      authed(),
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{"mutations" => [%{"patch" => patch}]})
    )
  end

  test "the rev GET /v1/tasks/:id serves is ACCEPTED, and the patch lands where that GET reads",
       %{scope: scope} do
    id = mk_published_task!(scope, %{"note" => "before"})

    before = get_task(id)
    assert before["content"]["note"] == "before"
    rev = before["rev"]
    assert is_binary(rev)

    resp = post_patch(id, %{"note" => "after"}, rev)

    assert resp.status == 200,
           "the rev the task API served must not 412 at the mutate door: #{resp.resp_body}"

    body = Jason.decode!(resp.resp_body)
    [result] = body["results"]

    assert result["id"] == id,
           "the receipt must name the row readers serve, not drafts.#{id}: #{inspect(result)}"

    assert get_task(id)["content"]["note"] == "after",
           "a 200 that the task API cannot see is the defect this row was filed for"

    assert {:error, :not_found} =
             Content.get_document(DraftId.draft_id(id), "task", @dataset, scope),
           "no invisible twin may be left behind"
  end

  test "a patch is REFUSED, naming drafts.<id>, when a twin already exists", %{scope: scope} do
    id = mk_published_task!(scope, %{"note" => "published"})

    # The forked state 22 live rows were found in.
    {:ok, _twin} =
      Content.create_document(
        "task",
        %{"doc_id" => id, "title" => id, "content" => task_content(%{"note" => "stale twin"})},
        @dataset,
        scope
      )

    rev = get_task(id)["rev"]
    resp = post_patch(id, %{"note" => "after"}, rev)

    assert resp.status == 422, "expected a refusal, got #{resp.status}: #{resp.resp_body}"
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "validation_failed"

    [message] = body["error"]["details"]["_id"]
    assert message =~ "drafts.#{id}"
    assert message =~ "discardDraft"

    assert get_task(id)["content"]["note"] == "published", "a refused patch writes nothing"
  end
end
