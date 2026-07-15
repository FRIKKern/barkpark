defmodule BarkparkWeb.CycleFleetControllerTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{CycleFleet, Repo, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet.AssignmentTask
  alias Barkpark.EpicFleet
  alias Barkpark.Plugins.Capabilities
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup do
    {workspace, project} = ensure_default_scope!()
    raw = "cycle-http-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "cycle-http",
        dataset: "test",
        permissions: ["read", "write"]
      })
      |> Repo.insert()

    {:ok, _membership} =
      TenancyAuth.create_membership(workspace.id, token.id, "admin", "api_token")

    %{workspace: workspace, project: project, token: raw}
  end

  test "flat routes are token-bound projectless legacy routes distinct from canonical scoped routes",
       %{workspace: workspace, project: project, token: token} do
    epic_id = "scope-http-#{System.unique_integer([:positive])}"
    flat = "/v1/cycles/#{epic_id}/wave-1"
    scoped = "/w/#{workspace.slug}/p/#{project.slug}" <> flat

    flat_open = open_epic(flat, token, ["flat-unit"])
    scoped_open = open_epic(scoped, token, ["scoped-unit"])

    assert flat_open["authority"]["workspace_id"] == workspace.id
    assert flat_open["authority"]["project_id"] == nil
    assert flat_open["authority"]["connection"]["project"] == nil

    assert scoped_open["authority"]["workspace_id"] == workspace.id
    assert scoped_open["authority"]["project_id"] == project.id

    assert scoped_open["authority"]["connection"]["project"] == %{
             "id" => project.id,
             "slug" => project.slug
           }

    refute flat_open["authority"]["wave_revision"] ==
             scoped_open["authority"]["wave_revision"]

    assert get_cycle(flat, token)["cycle_ledger"]["inventory_count"] == 1
    assert get_cycle(scoped, token)["cycle_ledger"]["inventory_count"] == 1
  end

  test "the same logical cycle is separated between projects", %{
    workspace: workspace,
    project: first_project,
    token: token
  } do
    second_project = create_project!(workspace, "cycle-project-two")
    epic_id = "project-http-#{System.unique_integer([:positive])}"
    suffix = "/v1/cycles/#{epic_id}/wave-1"
    first = "/w/#{workspace.slug}/p/#{first_project.slug}" <> suffix
    second = "/w/#{workspace.slug}/p/#{second_project.slug}" <> suffix

    first_open = open_epic(first, token, ["first"])
    second_open = open_epic(second, token, ["second"])

    assert first_open["authority"]["project_id"] == first_project.id
    assert second_open["authority"]["project_id"] == second_project.id
    refute first_open["authority"]["wave_revision"] == second_open["authority"]["wave_revision"]
  end

  test "Legendary seal is refused before 15 experiments and freezes Pilot evidence after them", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "legendary-http-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"

    opened = open_legendary(base, token, 15)
    assert opened["cycle_ledger"]["scale_contract"] == stringify_keys(scale_contract(15))
    refute opened["cycle_ledger"]["capacity"]["sealed"]

    rejected =
      build_conn()
      |> bearer(token)
      |> post(base <> "/seal", seal_params())
      |> json_response(422)

    assert rejected["error"]["code"] == "validation_failed"
    assert rejected["error"]["details"]["reason"] =~ "experiment_assignments_incomplete"

    complete_http_experiments(base, token)

    sealed =
      build_conn()
      |> bearer(token)
      |> post(base <> "/seal", seal_params())
      |> json_response(200)

    assert sealed["cycle_ledger"]["capacity"]["sealed"]

    assert sealed["cycle_ledger"]["capacity"]["golden_fixtures"] == [
             "paper://fixtures/bad",
             "paper://fixtures/good"
           ]

    assert sealed["cycle_ledger"]["capacity"]["quality_rubric"] ==
             stringify_keys(quality_rubric())

    assert sealed["cycle_ledger"]["planned_builders"] == 15
  end

  test "seal returns 422 for map and list numeric inputs without crashing", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "legendary-http-malformed-numbers-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_legendary(base, token, 1)
    complete_http_experiments(base, token)

    for {field, malformed} <- [
          {"proven_batch_capacity", [1]},
          {"failure_rate", %{"value" => 0.0}},
          {"failure_threshold", [0.05]}
        ] do
      response =
        build_conn()
        |> bearer(token)
        |> post(base <> "/seal", Map.put(seal_params(), field, malformed))
        |> json_response(422)

      assert response["error"]["code"] == "validation_failed"
    end
  end

  test "results and replacements resolve logical assignment ids inside the scoped wave", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "legendary-http-result-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"

    open_legendary(base, token, 1)
    complete_http_experiments(base, token)

    build_conn()
    |> bearer(token)
    |> post(base <> "/seal", seal_params())
    |> json_response(200)

    original = create_http_assignment(base, token, "build-1", nil)
    assert original["assignment"]["assignment_id"] == "build-1"

    create_http_result(base, token, "build-1", "failed", %{})

    replacement = create_http_assignment(base, token, "build-1-retry", "build-1")

    assert replacement["assignment"]["replaces_assignment_id"] ==
             original["assignment"]["id"]

    result =
      create_http_result(base, token, "build-1-retry", "completed", %{
        "completed_unit_ids" => ["unit-1"]
      })

    assert result["result"]["status"] == "completed"

    ledger = get_cycle(base, token)["cycle_ledger"]
    assert ledger["assigned_count"] == 1
    assert ledger["shipped_count"] == 1
  end

  test "bp cycle capabilities use canonical scoped paths without ScopedMirror hints" do
    commands =
      Capabilities.manifest("admin", project: false)["commands"]
      |> Enum.filter(&String.starts_with?(&1["id"], "cycle."))

    assert MapSet.new(commands, & &1["id"]) ==
             MapSet.new(~w(cycle.show cycle.open cycle.seal cycle.assign cycle.result))

    for command <- commands do
      assert String.starts_with?(
               command["http"]["path_template"],
               "/w/:workspace_slug/p/:project_slug/v1/cycles/"
             )

      refute Map.has_key?(command, "scoped_prefix")
    end

    open = Enum.find(commands, &(&1["id"] == "cycle.open"))
    seal = Enum.find(commands, &(&1["id"] == "cycle.seal"))
    assign = Enum.find(commands, &(&1["id"] == "cycle.assign"))
    assert required_arg?(open, "scale_contract_json")
    assert required_arg?(seal, "golden_fixtures_json")

    assert Enum.any?(
             assign["flags"],
             &(&1["name"] == "task_id" and &1["type"] == "string")
           )
  end

  test "scoped assignment freezes a same-project Task and replays without rebinding", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "cycle-task-binding-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    task = create_task!(workspace, project, "bound")
    other_task = create_task!(workspace, project, "other")
    open_epic(base, token, ["unit-1"])

    params = %{
      "assignment_id" => "build-1",
      "phase" => "build",
      "agent_type" => "epic-builder",
      "effort" => "high",
      "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]}),
      "task_id" => task.id,
      "workspace_id" => Ecto.UUID.generate(),
      "project_id" => Ecto.UUID.generate(),
      "claim" => %{"worker_id" => "caller-authored"}
    }

    created =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", params)
      |> json_response(201)

    assignment_id = created["assignment"]["id"]
    binding = Repo.get!(AssignmentTask, assignment_id)
    assert binding.task_id == task.id

    replayed =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", params)
      |> json_response(201)

    assert replayed == created
    replayed_binding = Repo.get!(AssignmentTask, assignment_id)
    assert replayed_binding.task_id == binding.task_id
    assert replayed_binding.inserted_at == binding.inserted_at

    conflict =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", Map.put(params, "task_id", other_task.id))
      |> json_response(422)

    assert conflict["error"]["details"]["reason"] == ":assignment_task_conflict"
    assert Repo.get!(AssignmentTask, assignment_id).task_id == task.id
  end

  test "missing and cross-project Task authority roll back scoped assignments", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    other_project = create_project!(workspace, "cycle-task-binding-other")
    foreign_task = create_task!(workspace, other_project, "foreign")
    epic_id = "cycle-task-authority-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    for {logical_id, task_id} <- [
          {"missing-task", Ecto.UUID.generate()},
          {"foreign-task", foreign_task.id}
        ] do
      rejected =
        build_conn()
        |> bearer(token)
        |> post(base <> "/assignments", %{
          "assignment_id" => logical_id,
          "phase" => "build",
          "agent_type" => "epic-builder",
          "effort" => "high",
          "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]}),
          "task_id" => task_id,
          "project_id" => other_project.id
        })
        |> json_response(422)

      assert rejected["error"]["details"]["reason"] ==
               ":assignment_task_authority_not_found"

      refute CycleFleet.get_assignment(
               %{
                 workspace_id: workspace.id,
                 project_id: project.id,
                 epic_id: epic_id,
                 wave_id: "wave-1"
               },
               logical_id
             )
    end
  end

  test "flat projectless legacy assignment remains valid without a Task binding", %{
    workspace: workspace,
    token: token
  } do
    epic_id = "cycle-task-binding-legacy-#{System.unique_integer([:positive])}"
    base = "/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    created = create_http_epic_assignment(base, token, "legacy-build-1")
    assignment_id = created["assignment"]["id"]

    assert CycleFleet.get_assignment(
             %{
               workspace_id: workspace.id,
               project_id: nil,
               epic_id: epic_id,
               wave_id: "wave-1"
             },
             "legacy-build-1"
           )

    refute Repo.get(AssignmentTask, assignment_id)
  end

  test "flat route derives its workspace from the bound token", %{conn: conn} do
    workspace = create_workspace!("cycle-owned")
    _project = create_project!(workspace, "cycle-owned")
    raw = "cycle-owned-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "cycle-owned",
        dataset: "test",
        permissions: ["read", "write"],
        workspace_id: workspace.id
      })
      |> Repo.insert()

    {:ok, _membership} =
      TenancyAuth.create_membership(workspace.id, token.id, "admin", "api_token")

    body =
      conn
      |> bearer(raw)
      |> post("/v1/cycles/owned-epic/wave-1/open", %{
        "profile" => "epic",
        "inventory" => [],
        "scale_contract" => %{}
      })
      |> json_response(201)

    assert body["authority"]["workspace_id"] == workspace.id
    assert body["authority"]["project_id"] == nil
    assert body["authority"]["connection"]["workspace"]["slug"] == workspace.slug
  end

  test "read and write permissions are enforced", %{conn: conn} do
    assert conn |> get("/v1/cycles/epic/wave") |> json_response(401)

    raw = "cycle-read-" <> Ecto.UUID.generate()
    {:ok, _token} = Barkpark.Auth.create_token(raw, "cycle-read", "test", ["read"])

    response =
      conn
      |> bearer(raw)
      |> post("/v1/cycles/epic/wave/open", %{
        "profile" => "epic",
        "inventory" => [],
        "scale_contract" => %{}
      })

    assert json_response(response, 403)
  end

  test "public-read tokens cannot read flat or scoped CycleFleet while read tokens can", %{
    workspace: workspace,
    project: project,
    token: write_token
  } do
    epic_id = "cycle-public-read-#{System.unique_integer([:positive])}"
    flat = "/v1/cycles/#{epic_id}/wave-1"
    scoped = "/w/#{workspace.slug}/p/#{project.slug}" <> flat
    open_epic(flat, write_token, ["flat-unit"])
    open_epic(scoped, write_token, ["scoped-unit"])

    public_read = scoped_token!(workspace, ["public-read"], "cycle-public-read")
    read = scoped_token!(workspace, ["read"], "cycle-read")

    for path <- [flat, scoped] do
      denied = build_conn() |> bearer(public_read) |> get(path)
      assert json_response(denied, 403)["error"]["code"] == "forbidden"

      allowed = build_conn() |> bearer(read) |> get(path) |> json_response(200)
      assert allowed["cycle_ledger"]["profile"] == "epic"
    end
  end

  test "immutable replay conflicts map the actual context atoms to 409", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "cycle-conflict-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    assert build_conn()
           |> bearer(token)
           |> post(base <> "/open", %{
             "profile" => "epic",
             "inventory_json" => Jason.encode!(["unit-1"]),
             "scale_contract_json" => "{}"
           })
           |> json_response(201)

    wave_conflict =
      build_conn()
      |> bearer(token)
      |> post(base <> "/open", %{
        "profile" => "epic",
        "inventory_json" => Jason.encode!(["different"]),
        "scale_contract_json" => "{}"
      })
      |> json_response(409)

    assert wave_conflict["error"]["details"]["reason"] == "wave_conflict"

    assignment_params = %{
      "assignment_id" => "build-1",
      "phase" => "build",
      "agent_type" => "epic-builder",
      "effort" => "high",
      "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]})
    }

    created =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", assignment_params)
      |> json_response(201)

    replayed =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", assignment_params)
      |> json_response(201)

    assignment = created["assignment"]
    assert replayed["assignment"] == assignment
    assert assignment["cycle_assignment_id"] == assignment["id"]
    assert assignment["unit_ids"] == ["unit-1"]
    assert assignment["cycle_wave_id"] =~ ~r/^[0-9a-f-]{36}$/
    assert assignment["inventory_digest"] =~ ~r/^[0-9a-f]{64}$/
    assert assignment["snapshot_digest"] =~ ~r/^[0-9a-f]{64}$/

    projection = get_cycle(base, token)

    assert projection["assignment_attributions"] == [
             %{
               "cycle_assignment_id" => assignment["id"],
               "cycle_wave_id" => assignment["cycle_wave_id"],
               "assignment_id" => "build-1",
               "unit_ids" => ["unit-1"],
               "inventory_digest" => assignment["inventory_digest"],
               "snapshot_digest" => assignment["snapshot_digest"]
             }
           ]

    assignment_conflict =
      build_conn()
      |> bearer(token)
      |> post(
        base <> "/assignments",
        Map.put(
          assignment_params,
          "snapshot_json",
          Jason.encode!(%{"unit_ids" => ["unit-1"], "changed" => true})
        )
      )
      |> json_response(409)

    assert assignment_conflict["error"]["details"]["reason"] == "assignment_conflict"

    result_params = %{
      "idempotency_key" => "terminal-build-1",
      "status" => "completed",
      "evidence" => "paper://build/1",
      "evidence_revision" => "rev-1",
      "payload_json" =>
        Jason.encode!(%{
          "completed_unit_ids" => ["unit-1"],
          "stalled_unit_ids" => [],
          "excluded_unit_ids" => []
        })
    }

    assert build_conn()
           |> bearer(token)
           |> post(base <> "/assignments/build-1/results", result_params)
           |> json_response(201)

    idempotency_conflict =
      build_conn()
      |> bearer(token)
      |> post(
        base <> "/assignments/build-1/results",
        Map.put(
          result_params,
          "payload_json",
          Jason.encode!(%{
            "completed_unit_ids" => [],
            "stalled_unit_ids" => ["unit-1"],
            "excluded_unit_ids" => []
          })
        )
      )
      |> json_response(409)

    assert idempotency_conflict["error"]["details"]["reason"] == "idempotency_conflict"

    terminal_conflict =
      build_conn()
      |> bearer(token)
      |> post(
        base <> "/assignments/build-1/results",
        Map.put(result_params, "idempotency_key", "other-terminal-key")
      )
      |> json_response(409)

    assert terminal_conflict["error"]["details"]["reason"] == "terminal_result_conflict"
  end

  test "scoped replacement phase mismatch returns 409 with the immutable reason", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "cycle-replacement-phase-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    create_http_epic_assignment(base, token, "build-1")

    conflict =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => "verify-retry",
        "phase" => "verify",
        "agent_type" => "epic-verifier",
        "effort" => "medium",
        "snapshot_json" => "{}",
        "replaces_assignment_id" => "build-1"
      })
      |> json_response(409)

    assert conflict["error"]["details"]["reason"] == "replacement_phase_mismatch"
  end

  test "scoped replacement agent mismatch is 409 while predecessor state remains 422", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "cycle-replacement-validation-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    create_http_epic_assignment(base, token, "build-1")

    invalid_agent =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => "build-invalid-agent",
        "phase" => "build",
        "agent_type" => "code-reviewer",
        "effort" => "high",
        "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]}),
        "replaces_assignment_id" => "build-1"
      })
      |> json_response(409)

    assert invalid_agent["error"]["details"]["reason"] ==
             "replacement_agent_type_mismatch"

    pending_predecessor =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => "build-pending-retry",
        "phase" => "build",
        "agent_type" => "epic-builder",
        "effort" => "high",
        "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]}),
        "replaces_assignment_id" => "build-1"
      })
      |> json_response(422)

    assert pending_predecessor["error"]["details"]["reason"] ==
             ":replacement_predecessor_pending"

    create_http_result(base, token, "build-1", "completed", %{
      "completed_unit_ids" => ["unit-1"]
    })

    non_replaceable =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => "build-completed-retry",
        "phase" => "build",
        "agent_type" => "epic-builder",
        "effort" => "high",
        "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]}),
        "replaces_assignment_id" => "build-1"
      })
      |> json_response(422)

    assert non_replaceable["error"]["details"]["reason"] ==
             ":replacement_predecessor_not_replaceable"
  end

  test "flat replacement exposes same-workspace legacy contract mismatch as 409", %{
    workspace: workspace,
    token: token
  } do
    epic_id = "cycle-replacement-contract-#{System.unique_integer([:positive])}"
    base = "/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    assert {:ok, _legacy} =
             EpicFleet.create_assignment(%{
               workspace_id: workspace.id,
               epic_id: epic_id,
               wave_id: "wave-1",
               assignment_id: "legacy-build-1",
               phase: "build",
               agent_type: "epic-builder",
               effort: "high",
               snapshot: %{"unit_ids" => ["unit-1"]}
             })

    conflict =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => "cycle-build-retry",
        "phase" => "build",
        "agent_type" => "epic-builder",
        "effort" => "high",
        "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]}),
        "replaces_assignment_id" => "legacy-build-1"
      })
      |> json_response(409)

    assert conflict["error"]["details"]["reason"] == "replacement_contract_mismatch"
  end

  test "scoped replacement lookup does not cross the project wave contract", %{
    workspace: workspace,
    project: first_project,
    token: token
  } do
    second_project = create_project!(workspace, "cycle-replacement-project-two")
    epic_id = "cycle-replacement-scope-#{System.unique_integer([:positive])}"
    suffix = "/v1/cycles/#{epic_id}/wave-1"
    first = "/w/#{workspace.slug}/p/#{first_project.slug}" <> suffix
    second = "/w/#{workspace.slug}/p/#{second_project.slug}" <> suffix
    open_epic(first, token, ["unit-1"])
    open_epic(second, token, ["unit-2"])

    create_http_epic_assignment(first, token, "build-1")

    not_found =
      build_conn()
      |> bearer(token)
      |> post(second <> "/assignments", %{
        "assignment_id" => "build-retry",
        "phase" => "build",
        "agent_type" => "epic-builder",
        "effort" => "high",
        "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-2"]}),
        "replaces_assignment_id" => "build-1"
      })
      |> json_response(422)

    assert not_found["error"]["details"]["reason"] == ":replacement_not_found"
  end

  test "authority classification uses canonical server config, not spoofed request Host", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    previous = Application.get_env(:barkpark, :capabilities_base_url)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :capabilities_base_url, previous),
        else: Application.delete_env(:barkpark, :capabilities_base_url)
    end)

    epic_id = "cycle-authority-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    Application.put_env(:barkpark, :capabilities_base_url, "http://127.0.0.1:4000")

    local =
      build_conn()
      |> Map.put(:host, "spoofed.cloud.example")
      |> bearer(token)
      |> get(base)
      |> json_response(200)

    assert local["authority"]["connection"]["execution_location"] == "local"
    assert local["authority"]["connection"]["server_origin"] == "http://127.0.0.1:4000"

    Application.put_env(:barkpark, :capabilities_base_url, "https://api.barkpark.cloud")

    remote =
      build_conn()
      |> Map.put(:host, "localhost")
      |> bearer(token)
      |> get(base)
      |> json_response(200)

    assert remote["authority"]["connection"]["execution_location"] == "remote"

    assert remote["authority"]["connection"]["server_origin"] ==
             "https://api.barkpark.cloud"

    assert remote["authority"]["connection"]["workspace"]["id"] == workspace.id
    assert remote["authority"]["connection"]["project"]["id"] == project.id
  end

  test "HTTP replay remains idempotent at full phase capacity", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "cycle-full-replay-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    params = fn index ->
      %{
        "assignment_id" => "review-#{index}",
        "phase" => "review",
        "agent_type" => "code-reviewer",
        "effort" => "high",
        "snapshot_json" => "{}"
      }
    end

    for index <- 1..3 do
      assert build_conn()
             |> bearer(token)
             |> post(base <> "/assignments", params.(index))
             |> json_response(201)
    end

    assert build_conn()
           |> bearer(token)
           |> post(base <> "/assignments", params.(3))
           |> json_response(201)

    conflict =
      build_conn()
      |> bearer(token)
      |> post(
        base <> "/assignments",
        Map.put(params.(3), "snapshot_json", Jason.encode!(%{"changed" => true}))
      )
      |> json_response(409)

    assert conflict["error"]["details"]["reason"] == "assignment_conflict"

    exhausted =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", params.(4))
      |> json_response(422)

    assert exhausted["error"]["details"]["reason"] =~
             "phase_assignment_capacity_exhausted"
  end

  test "HTTP rejects over-capacity build shards and post-seal experiments", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "legendary-http-capacity-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_legendary(base, token, 2)
    complete_http_experiments(base, token)

    build_conn()
    |> bearer(token)
    |> post(base <> "/seal", seal_params())
    |> json_response(200)

    too_wide =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => "build-too-wide",
        "phase" => "build",
        "agent_type" => "legendary-builder",
        "effort" => "medium",
        "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1", "unit-2"]})
      })
      |> json_response(422)

    assert too_wide["error"]["details"]["reason"] =~ "proven_batch_capacity_exceeded"

    post_seal =
      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => "experiment-after-seal",
        "phase" => "experiment",
        "agent_type" => "legendary-experimenter",
        "effort" => "medium",
        "snapshot_json" => "{}"
      })
      |> json_response(422)

    assert post_seal["error"]["details"]["reason"] =~ "experiment_phase_sealed"
  end

  defp open_epic(base, token, inventory) do
    build_conn()
    |> bearer(token)
    |> post(base <> "/open", %{
      "profile" => "epic",
      "inventory_json" => Jason.encode!(inventory),
      "scale_contract_json" => "{}"
    })
    |> json_response(201)
  end

  defp open_legendary(base, token, count) do
    count = max(count, 15)
    inventory = Enum.map(1..count, &%{"unit_id" => "unit-#{&1}"})

    build_conn()
    |> bearer(token)
    |> post(base <> "/open", %{
      "profile" => "legendary",
      "inventory_json" => Jason.encode!(inventory),
      "scale_contract_json" => Jason.encode!(scale_contract(count))
    })
    |> json_response(201)
  end

  defp complete_http_experiments(base, token) do
    for {round, round_index} <- Enum.with_index(~w(baseline diverge attack converge pilot)),
        candidate <- 1..3 do
      id = "experiment-#{round_index + 1}-#{candidate}"

      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => id,
        "phase" => "experiment",
        "agent_type" => "legendary-experimenter",
        "effort" => "medium",
        "snapshot_json" => "{}"
      })
      |> json_response(201)

      build_conn()
      |> bearer(token)
      |> post(base <> "/assignments/#{id}/results", %{
        "idempotency_key" => "terminal-#{id}",
        "status" => "completed",
        "evidence" => "paper://experiments/#{id}",
        "evidence_revision" => "rev-1",
        "payload_json" => Jason.encode!(%{round: round, candidate: candidate})
      })
      |> json_response(201)
    end
  end

  defp create_http_assignment(base, token, id, replaces) do
    params = %{
      "assignment_id" => id,
      "phase" => "build",
      "agent_type" => "legendary-builder",
      "effort" => "medium",
      "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]})
    }

    params = if replaces, do: Map.put(params, "replaces_assignment_id", replaces), else: params

    build_conn()
    |> bearer(token)
    |> post(base <> "/assignments", params)
    |> json_response(201)
  end

  defp create_http_epic_assignment(base, token, id) do
    build_conn()
    |> bearer(token)
    |> post(base <> "/assignments", %{
      "assignment_id" => id,
      "phase" => "build",
      "agent_type" => "epic-builder",
      "effort" => "high",
      "snapshot_json" => Jason.encode!(%{"unit_ids" => ["unit-1"]})
    })
    |> json_response(201)
  end

  defp create_http_result(base, token, assignment_id, status, payload) do
    payload =
      if status == "completed" do
        Map.merge(
          %{
            "completed_unit_ids" => [],
            "stalled_unit_ids" => [],
            "excluded_unit_ids" => []
          },
          payload
        )
      else
        payload
      end

    build_conn()
    |> bearer(token)
    |> post(base <> "/assignments/#{assignment_id}/results", %{
      "idempotency_key" => "terminal-#{assignment_id}",
      "status" => status,
      "evidence" => "paper://build/#{assignment_id}",
      "evidence_revision" => "rev-1",
      "payload_json" => Jason.encode!(payload)
    })
    |> json_response(201)
  end

  defp get_cycle(base, token) do
    build_conn()
    |> bearer(token)
    |> get(base)
    |> json_response(200)
  end

  defp scale_contract(count) do
    %{
      unit_definition: "Paper repair target",
      unit_count: count,
      inventory_evidence: "bp doc list paper --all -o json",
      target_surfaces: ["Studio", "TUI", "email"],
      concurrency_width: 3,
      minimum_multiplier: 5,
      build_formula: "max(15, ceil(unit_count / proven_batch_capacity))",
      excluded_inventory: [],
      quality_rubric: quality_rubric(),
      failure_threshold: 0.05
    }
  end

  defp quality_rubric do
    %{
      reader_visibility: "all target readers pass",
      preservation: "authored content is byte-preserved"
    }
  end

  defp seal_params do
    %{
      "proven_batch_capacity" => "1",
      "chosen_format" => "paper-reader-v1",
      "pilot_evidence" => "paper://pilot/reader-v1",
      "pilot_evidence_revision" => "rev-1",
      "failure_rate" => "0.0",
      "failure_threshold" => "0.05",
      "golden_fixtures_json" => Jason.encode!(["paper://fixtures/good", "paper://fixtures/bad"])
    }
  end

  defp create_task!(workspace, project, suffix) do
    {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")

    %Document{}
    |> Document.changeset(%{
      doc_id: "drafts.cycle-http-task-#{suffix}-#{System.unique_integer([:positive])}",
      type: "task",
      dataset: "production",
      title: "Cycle HTTP Task #{suffix}",
      status: "draft",
      content: %{"kind" => "task", "lifecycle_status" => "open"},
      rev: Ecto.UUID.generate(),
      workspace_id: workspace.id,
      project_id: project.id,
      dataset_id: dataset.id
    })
    |> Repo.insert!()
  end

  defp required_arg?(command, name) do
    Enum.any?(command["args"], &(&1["name"] == name and &1["required"] == true))
  end

  defp scoped_token!(workspace, permissions, label) do
    raw = label <> "-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: label,
        dataset: "test",
        permissions: permissions,
        workspace_id: workspace.id
      })
      |> Repo.insert()

    {:ok, _membership} =
      TenancyAuth.create_membership(workspace.id, token.id, "member", "api_token")

    raw
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp bearer(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
  end
end
