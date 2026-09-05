defmodule Barkpark.Tasks.ExecutionPolicyTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.{Close, ExecutionPolicy, Internal, Validation, WorkDigest}

  @dataset "production"
  @token "barkpark-test-execution-policy-token"

  setup do
    {:ok, _} = Auth.create_token(@token, "execution-policy", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  test "schema exposes an optional strict advisory composite" do
    field = Enum.find(Tasks.task_schema().fields, &(&1["name"] == "execution_policy"))

    assert field["type"] == "composite"

    assert Enum.map(field["fields"], & &1["name"]) ==
             ~w(version agent_type model reasoning_effort resource_class)
  end

  test "absent policy is compatible and version 1 rejects unsafe or unknown fields" do
    base = %{
      "kind" => "task",
      "acceptance_criteria" => [
        %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
      ],
      "lifecycle_status" => "open"
    }

    assert :ok = Validation.validate_task_content(base)

    valid = %{
      "version" => 1,
      "agent_type" => "executor",
      "model" => "gpt-5.6-sol",
      "reasoning_effort" => "high",
      "resource_class" => "heavy"
    }

    assert :ok = Validation.validate_task_content(Map.put(base, "execution_policy", valid))

    for unsafe <- ~w(command env environment cwd secret secrets permissions security sandbox) do
      policy = %{"version" => 1, unsafe => "unsafe"}

      assert {:error, %{"execution_policy" => errors}} =
               Validation.validate_task_content(Map.put(base, "execution_policy", policy))

      assert Map.has_key?(errors, unsafe)
    end

    assert {:error, %{"execution_policy" => %{"version" => [_ | _]}}} =
             Validation.validate_task_content(
               Map.put(base, "execution_policy", %{"version" => 2})
             )

    assert {:error, %{"execution_policy" => %{"reasoning_effort" => [_ | _]}}} =
             Validation.validate_task_content(
               Map.put(base, "execution_policy", %{
                 "version" => 1,
                 "reasoning_effort" => "unbounded"
               })
             )
  end

  test "resolver sanitizes every layer and resolves each field by explicit > task > session > provider" do
    explicit = %{"version" => 1, "model" => " explicit-model "}
    task = %{"version" => 1, "agent_type" => "executor", "model" => "task-model"}
    session = %{"version" => 1, "reasoning_effort" => "high", "model" => "session-model"}
    provider = %{"version" => 1, "resource_class" => "heavy", "model" => "provider-model"}

    assert {:ok, snapshot} = ExecutionPolicy.resolve(explicit, task, session, provider)

    assert snapshot["resolved"] == %{
             "agent_type" => "executor",
             "model" => "explicit-model",
             "reasoning_effort" => "high",
             "resource_class" => "heavy"
           }

    assert snapshot["sources"] == %{
             "agent_type" => "task",
             "model" => "explicit",
             "reasoning_effort" => "session",
             "resource_class" => "provider"
           }

    assert [%{"field" => "model", "source" => "explicit"} = notice] = snapshot["notices"]
    assert notice["overrode"] == ~w(task session provider)

    assert {:error, %{"session.command" => [_ | _]}} =
             ExecutionPolicy.resolve(nil, nil, %{"version" => 1, "command" => "no"}, nil)
  end

  test "work digest preserves absent parity and fences policy add/edit/remove" do
    legacy = %{
      "kind" => "task",
      "acceptance_criteria" => [
        %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
      ],
      "lifecycle_status" => "open"
    }

    legacy_fields = WorkDigest.field_digests("task", legacy)

    assert Map.keys(legacy_fields) |> Enum.sort() ==
             ~w(acceptance_criteria brief description title)

    policy = %{"version" => 1, "agent_type" => "executor"}
    requested = Map.put(legacy, "execution_policy", policy)
    stored = WorkDigest.field_digests("task", requested)

    assert WorkDigest.changed_fields(stored, "task", requested) == []

    assert WorkDigest.changed_fields(
             stored,
             "task",
             put_in(requested, ["execution_policy", "agent_type"], "verifier")
           ) == ["execution_policy"]

    assert WorkDigest.changed_fields(stored, "task", Map.delete(requested, "execution_policy")) ==
             ["execution_policy"]

    assert WorkDigest.changed_fields(legacy_fields, "task", requested) == ["execution_policy"]
  end

  test "targeted claim freezes the resolved snapshot and renewal preserves it", %{scope: scope} do
    task =
      mk_task!(uniq("policy-target"), scope, %{
        "execution_policy" => %{
          "version" => 1,
          "agent_type" => "executor",
          "model" => "task-model"
        }
      })

    opts =
      scope ++
        [
          execution_policy_override: %{"version" => 1, "model" => "explicit-model"},
          session_execution_policy: %{"version" => 1, "reasoning_effort" => "high"},
          provider_execution_policy: %{"version" => 1, "resource_class" => "heavy"}
        ]

    assert {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "policy-worker", opts)
    snapshot = claimed.content["claim"]["execution_policy"]
    assert snapshot["resolved"]["model"] == "explicit-model"
    assert snapshot["resolved"]["agent_type"] == "executor"
    assert snapshot["resolved"]["reasoning_effort"] == "high"
    assert snapshot["resolved"]["resource_class"] == "heavy"

    assert {:ok, renewed} =
             Tasks.claim_by_id(
               task.doc_id,
               "policy-worker",
               scope ++
                 [execution_policy_override: %{"version" => 1, "model" => "changed"}]
             )

    assert renewed.content["claim"]["execution_policy"] == snapshot
  end

  test "same-worker renewal validates every supplied policy layer without replacing the snapshot",
       %{scope: scope} do
    task =
      mk_task!(uniq("policy-renew-layers"), scope, %{
        "execution_policy" => %{"version" => 1, "agent_type" => "executor"}
      })

    assert {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "policy-worker", scope)
    original_claim = claimed.content["claim"]

    invalid_layers = [
      {:execution_policy_override, %{"version" => 1, "command" => "unsafe"}, "explicit.command"},
      {:execution_policy_override, %{"version" => 1, "reasoning_effort" => "unbounded"},
       "explicit.reasoning_effort"},
      {:session_execution_policy, %{"version" => 1, "command" => "unsafe"}, "session.command"},
      {:provider_execution_policy, %{"version" => 1, "command" => "unsafe"}, "provider.command"}
    ]

    for {layer, policy, error_key} <- invalid_layers do
      assert {:error, {:invalid_execution_policy, %{^error_key => [_ | _]}}} =
               Tasks.claim_by_id(
                 task.doc_id,
                 "policy-worker",
                 scope ++ [{layer, policy}]
               )

      persisted_claim = Repo.get!(Document, task.id).content["claim"]
      assert persisted_claim == original_claim
    end

    :ok =
      patch_content!(task.id, %{"execution_policy" => %{"version" => 1, "command" => "unsafe"}})

    assert {:error, {:invalid_execution_policy, %{"task.command" => [_ | _]}}} =
             Tasks.claim_by_id(task.doc_id, "policy-worker", scope)

    assert Repo.get!(Document, task.id).content["claim"] == original_claim
  end

  test "editing Task policy after claim trips the default close fence", %{scope: scope} do
    task =
      mk_task!(uniq("policy-fence"), scope, %{
        "execution_policy" => %{"version" => 1, "agent_type" => "executor"}
      })

    assert {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "policy-worker", scope)
    epoch = claimed.content["claim"]["epoch"]

    :ok =
      patch_content!(task.id, %{
        "execution_policy" => %{"version" => 1, "agent_type" => "verifier"}
      })

    assert {:error, {:doc_changed_since_claim, _rev, ["execution_policy"]}} =
             Close.close(task.id, "policy-worker",
               observed_epoch: epoch,
               lifecycle_status: "done"
             )
  end

  test "queue claim API round-trips requested and resolved policy; bad override is rejected",
       %{conn: conn, scope: scope} do
    phase = uniq("policy-api")

    task =
      mk_task!(uniq("policy-api-task"), scope, %{
        "parent_id" => phase,
        "execution_policy" => %{"version" => 1, "agent_type" => "executor"}
      })

    body =
      Jason.encode!(%{
        worker_id: "api-policy-worker",
        phase_id: phase,
        execution_policy_override: %{"version" => 1, "model" => "api-model"}
      })

    resp = conn |> authed() |> post("/v1/tasks/claim", body)
    assert resp.status == 200
    payload = Jason.decode!(resp.resp_body)
    assert payload["doc"]["doc_id"] == task.doc_id
    assert payload["doc"]["execution_policy"]["agent_type"] == "executor"

    assert payload["doc"]["claim"]["execution_policy"]["resolved"] == %{
             "agent_type" => "executor",
             "model" => "api-model"
           }

    bad = mk_task!(uniq("policy-api-bad"), scope)

    bad_resp =
      conn
      |> recycle()
      |> authed()
      |> post(
        "/v1/tasks/#{bad.doc_id}/claim",
        Jason.encode!(%{
          worker_id: "api-policy-worker",
          execution_policy_override: %{"version" => 1, "command" => "no"}
        })
      )

    assert bad_resp.status == 400
    assert Repo.get!(Document, bad.id).content["lifecycle_status"] == "open"
  end

  test "targeted claim HTTP rejects invalid and unknown overrides on same-worker renewal",
       %{conn: conn, scope: scope} do
    task =
      mk_task!(uniq("policy-api-renew"), scope, %{
        "execution_policy" => %{"version" => 1, "agent_type" => "executor"}
      })

    claim_resp =
      conn
      |> authed()
      |> post(
        "/v1/tasks/#{task.doc_id}/claim",
        Jason.encode!(%{worker_id: "api-policy-worker"})
      )

    assert claim_resp.status == 200
    claimed = Jason.decode!(claim_resp.resp_body)["doc"]["claim"]

    bad_overrides = [
      %{"version" => 1, "reasoning_effort" => "unbounded"},
      %{"version" => 1, "command" => "unsafe"}
    ]

    for override <- bad_overrides do
      renew_resp =
        conn
        |> recycle()
        |> authed()
        |> post(
          "/v1/tasks/#{task.doc_id}/claim",
          Jason.encode!(%{
            worker_id: "api-policy-worker",
            execution_policy_override: override
          })
        )

      assert renew_resp.status == 400
      assert Jason.decode!(renew_resp.resp_body)["ok"] == false

      persisted = Repo.get!(Document, task.id).content["claim"]
      assert persisted["epoch"] == claimed["epoch"]
      assert persisted["execution_policy"] == claimed["execution_policy"]
    end
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {key, value} -> {to_string(key), value} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open"
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp patch_content!(task_id, patch) do
    doc = Repo.get!(Document, task_id)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
      |> Repo.update_all(
        set: [content: Map.merge(doc.content, patch), rev: Internal.generate_rev()]
      )

    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
