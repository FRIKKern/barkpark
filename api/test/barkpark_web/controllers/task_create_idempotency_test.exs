defmodule BarkparkWeb.TaskCreateIdempotencyTest do
  @moduledoc """
  bl-api-task-create-idempotency, C0/C1 — the TASK-CREATE door, end to end.

  `bp task create` composes `POST /v1/data/mutate/<dataset>` itself
  (`internal/cli/tasks_create_cmd.go` → `sendCreateTaskMutations` →
  `apiclient.ScopedURL(..., "/v1/data/mutate/"+dataset)`), so the door this row
  is about is the mutate endpoint, not a `/v1/tasks` POST — there is no
  `{:post, "/tasks", …, :create}` route in `Barkpark.Plugins.Tasks`.

  The failure the row names: run.go's 30s client timeout fires, the caller
  retries, and a SECOND task row is filed for one intent. The `bp task create`
  error path says so in its own words — "ambiguous: the task may or may not
  have been filed … no id came back to re-check".

  The API-side remedy is the convention already in the tree: the
  `Idempotency-Key` request header, claim-first-deduped by
  `BarkparkWeb.Plugs.Idempotency` (mounted on BOTH mutate routes — flat
  `:idempotent`, router.ex:1148, and scoped `:scoped_mutate`, router.ex:456).
  These tests prove that convention actually holds for a task CREATE — the one
  mutation with no server-assigned id to re-read — over real HTTP.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, LabelFixtures, Tasks, TenancyFixtures}

  @token "barkpark-test-task-create-idem"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@token, "test-task-create-idem", "test", ["read", "write", "admin"])

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

    %{scope: scope}
  end

  defp authed(key) do
    conn =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")

    if key, do: put_req_header(conn, "idempotency-key", key), else: conn
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # EXACTLY the mutation `bp task create` composes (tasks_create_cmd.go).
  defp create_body(title) do
    Jason.encode!(%{
      "mutations" => [
        %{
          "create" => %{
            "_type" => "task",
            "title" => title,
            "content" =>
              LabelFixtures.with_registered_labels(
                %{"kind" => "task", "lifecycle_status" => "open"},
                @dataset
              )
          }
        }
      ]
    })
  end

  defp post_create(key, title),
    do: post(authed(key), "/v1/data/mutate/#{@dataset}", create_body(title))

  defp task_rows_titled(title, scope) do
    Content.list_documents("task", @dataset, scope)
    |> case do
      {:ok, %{documents: docs}} -> docs
      {:ok, docs} when is_list(docs) -> docs
      docs when is_list(docs) -> docs
    end
    |> Enum.filter(&(&1.title == title))
  end

  # ── C0 ────────────────────────────────────────────────────────────────────
  # The timeout-retry, replayed. Same key, same body, twice: ONE row, and the
  # second response hands back the ORIGINAL record so the retry still learns
  # the id it lost.
  #
  # MUTATION (the RED): drop the `Idempotency-Key` header from the second call
  # (or send a fresh key) and this test files TWO rows — which is the
  # `retried_titles` case below, kept in-tree as the standing contrast.
  test "a retry carrying the same Idempotency-Key replays the ORIGINAL record", %{scope: scope} do
    title = uniq("idem-create")
    key = uniq("key")

    first = post_create(key, title)
    assert first.status in 200..299, "first create: #{first.status} #{first.resp_body}"

    second = post_create(key, title)

    assert second.status == first.status,
           "the replay must reproduce the original status, got #{second.status}: #{second.resp_body}"

    assert second.resp_body == first.resp_body,
           "the replay must be BYTE-IDENTICAL to the original receipt — a retry that " <>
             "gets a different doc_id has double-filed"

    assert Enum.any?(second.resp_headers, &(&1 == {"idempotency-replay", "true"})),
           "a replayed response must say so: #{inspect(second.resp_headers)}"

    assert [_one] = task_rows_titled(title, scope)
  end

  # The contrast that makes the assertion above non-vacuous: WITHOUT a key,
  # the same create twice files two rows. This is the live defect the row
  # describes, pinned so a future change that makes creates accidentally
  # idempotent-by-title cannot make the C0 test pass for the wrong reason.
  test "two keyless creates of the same intent file TWO rows", %{scope: scope} do
    title = uniq("keyless-create")

    assert post_create(nil, title).status in 200..299
    assert post_create(nil, title).status in 200..299

    assert length(task_rows_titled(title, scope)) == 2,
           "if this ever reads 1, the C0 test above proves nothing"
  end

  # Two DIFFERENT keys are two different intents — dedup must not collapse them.
  test "distinct keys file distinct rows", %{scope: scope} do
    title = uniq("two-keys")

    assert post_create(uniq("k"), title).status in 200..299
    assert post_create(uniq("k"), title).status in 200..299

    assert length(task_rows_titled(title, scope)) == 2
  end

  # ── C1 ────────────────────────────────────────────────────────────────────
  # A create with NO key is byte-identical to today: same status, same envelope
  # keys, and NO idempotency-* response header.
  test "a keyless create's envelope is unchanged and carries no idempotency header" do
    resp = post_create(nil, uniq("plain-create"))

    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert Map.has_key?(body, "transactionId")
    assert [%{"id" => id}] = body["results"]
    assert is_binary(id)

    refute Enum.any?(resp.resp_headers, fn {k, _} -> String.starts_with?(k, "idempotency-") end),
           "a keyless request must not grow an idempotency header: #{inspect(resp.resp_headers)}"
  end
end
