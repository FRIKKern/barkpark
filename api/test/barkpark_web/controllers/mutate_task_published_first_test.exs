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

  # ── C2: the pr-task-gate hotfix-override record ────────────────────────────
  #
  # `.github/workflows/pr-task-gate.yml` step `hotfix_record` files the durable
  # bypass record with a `createIfNotExists` through this same door, and the
  # workflow never reads it back — the record's ONLY consumer is a human (or an
  # agent) running `bp task get hotfix-pr-<N>` / `bp task ready` / the board
  # afterwards, so "does it land where the gate reads it" is really "does it
  # land where those readers look". No prod access is needed to answer that: the
  # payload below is the gate's `jq -n` body verbatim (flat siblings, no
  # `content` map, ids and labels identical), replayed against a fixture, and
  # read back through the real `GET /v1/tasks/:id`.
  #
  # This path is DELIBERATELY NOT changed by this slice: `createIfNotExists`
  # keeps its draft-first lookup and its draft write, and the record resolves
  # because `find_task_by_doc_id/2`'s `drafts.` fallback finds an UNPAIRED
  # twin — which is also why `Tasks.Query.collapse_twins/1` admits it to the
  # ready queue AS ITSELF. The fix in this PR is scoped to `patch`.
  test "the pr-task-gate hotfix-override createIfNotExists lands where its readers look" do
    pr = System.unique_integer([:positive])
    id = "hotfix-pr-#{pr}"

    body =
      Jason.encode!(%{
        "mutations" => [
          %{
            "createIfNotExists" => %{
              "_id" => id,
              "_type" => "task",
              "title" => "hotfix override: a fixture PR",
              "kind" => "task",
              "lifecycle_status" => "open",
              "labels" => ["hotfix-override", "merge-gate-override", "proj:task-obsession"],
              "description" =>
                "Auto-filed by pr-task-gate for PR ##{pr} which merged under the hotfix! lane."
            }
          }
        ]
      })

    resp = post(authed(), "/v1/data/mutate/#{@dataset}", body)
    assert resp.status == 200, resp.resp_body

    [result] = Jason.decode!(resp.resp_body)["results"]

    assert result["id"] == "drafts.#{id}",
           "the record is written to the draft twin — the fact the read-back below is measuring"

    # THE READ-BACK. The gate's own consumers address the BARE id.
    doc = get_task(id)
    assert doc["content"]["kind"] == "task"
    assert doc["content"]["lifecycle_status"] == "open"
    assert doc["content"]["description"] =~ "pr-task-gate"
    assert "hotfix-override" in doc["content"]["labels"]

    # Idempotent re-run (the gate re-runs on every push): a second identical
    # call is a noop, not a duplicate.
    resp2 = post(authed(), "/v1/data/mutate/#{@dataset}", body)
    assert resp2.status == 200, resp2.resp_body
    [result2] = Jason.decode!(resp2.resp_body)["results"]
    assert result2["operation"] == "noop"
  end
end
