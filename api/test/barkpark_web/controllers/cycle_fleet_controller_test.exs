defmodule BarkparkWeb.CycleFleetControllerTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{CycleFleet, Repo, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet.{AssignmentTask, Wave}
  alias Barkpark.EpicFleet
  alias Barkpark.EpicFleet.Assignment
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

  test "public Paper verification failures return a stable 503 without internal details" do
    for reason <- [
          :public_release_smoke_failed,
          :public_release_smoke_pending,
          {:public_release_smoke_compensation_failed, {:database, "sensitive detail"}}
        ] do
      response =
        scoped_conn()
        |> BarkparkWeb.CycleFleetController.release_verification_unavailable(reason)

      assert response.status == 503
      body = Jason.decode!(response.resp_body)
      assert body["error"]["code"] == "release_verification_unavailable"
      refute response.resp_body =~ "sensitive"
      refute response.resp_body =~ "compensation_failed"
    end
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

  test "correction fields reach the HTTP authority and reject a wrong digest", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "correction-http-#{System.unique_integer([:positive])}"
    prefix = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}"
    _opened = open_epic(prefix <> "/wave-1", token, ["unit-1"])

    rejected =
      scoped_conn()
      |> bearer(token)
      |> post(prefix <> "/wave-2/open", %{
        "correction_of" => %{"version" => "correction_of-v1"},
        "correction_of_digest" => String.duplicate("0", 64)
      })
      |> json_response(422)

    assert rejected["error"]["code"] == "validation_failed"
    assert rejected["error"]["details"]["reason"] =~ "correction_digest_mismatch"
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
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/seal", seal_params())
      |> json_response(422)

    assert rejected["error"]["code"] == "validation_failed"
    assert rejected["error"]["details"]["reason"] =~ "experiment_assignments_incomplete"

    complete_http_experiments(base, token)

    sealed =
      scoped_conn()
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
        scoped_conn()
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

    scoped_conn()
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
             MapSet.new(
               ~w(cycle.show cycle.open cycle.release-gate-open cycle.release-paper-stage cycle.release-gate-activate cycle.seal cycle.assign cycle.result cycle.quarantine cycle.promote cycle.rollback)
             )

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
    refute required_arg?(open, "scale_contract_json")
    assert required_arg?(seal, "golden_fixtures_json")

    assert Enum.any?(
             assign["flags"],
             &(&1["name"] == "task_id" and &1["type"] == "string")
           )

    quarantine = Enum.find(commands, &(&1["id"] == "cycle.quarantine"))
    promote = Enum.find(commands, &(&1["id"] == "cycle.promote"))
    rollback = Enum.find(commands, &(&1["id"] == "cycle.rollback"))

    assert required_arg?(quarantine, "correction_receipt_json")
    assert required_arg?(promote, "gate_receipt_json")
    refute required_arg?(promote, "previous_event_id")
    assert required_arg?(rollback, "previous_event_id")
    assert required_arg?(rollback, "restore_event_id")

    refute Enum.any?(commands, fn command ->
             Enum.any?(
               List.wrap(command["args"]) ++ List.wrap(command["flags"]),
               &(&1["name"] == "actor")
             )
           end)
  end

  test "correction lifecycle writes are scoped-only and reject non-object or ambiguous receipts",
       %{
         workspace: workspace,
         project: project,
         token: token
       } do
    epic_id = "correction-lifecycle-http-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    opened = open_epic(base, token, ["unit-1"])
    immutable_revision = String.duplicate("d", 64)

    assert opened["correction_lifecycle"]["format"] == "quarantine-promotion-v1"
    assert opened["correction_lifecycle"]["promotion"] == nil
    assert opened["correction_lifecycle"]["quarantines"] == []
    assert opened["correction_lifecycle"]["superseded"] == []

    malformed =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/quarantine", %{
        "idempotency_key" => "quarantine-malformed",
        "reason" => "gate failed",
        "correction_receipt_json" => "[]",
        "actor" => %{"type" => "forged", "id" => "caller", "extra" => true},
        "evidence" => "paper://gate",
        "evidence_revision" => immutable_revision
      })
      |> json_response(422)

    assert malformed["error"]["details"]["reason"] =~ "invalid_correction_receipt"

    ambiguous =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/promote", %{
        "idempotency_key" => "promote-ambiguous",
        "correction_receipt" => %{},
        "correction_receipt_json" => "{}",
        "gate_receipt_json" => "{}",
        "evidence" => "paper://gate",
        "evidence_revision" => immutable_revision
      })
      |> json_response(422)

    assert ambiguous["error"]["details"]["reason"] =~ "ambiguous_correction_receipt"

    invalid_rollback =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/rollback", %{
        "idempotency_key" => "rollback-without-head",
        "previous_event_id" => Ecto.UUID.generate(),
        "restore_event_id" => "genesis",
        "evidence" => "paper://gate",
        "evidence_revision" => immutable_revision
      })
      |> json_response(422)

    assert invalid_rollback["error"]["details"]["reason"] =~ "invalid_rollback_target"

    flat_response =
      scoped_conn()
      |> bearer(token)
      |> post("/v1/cycles/#{epic_id}/wave-1/quarantine", %{
        "correction_receipt_json" => "{}"
      })

    assert flat_response.status == 404
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
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments", params)
      |> json_response(201)

    assignment_id = created["assignment"]["id"]
    binding = Repo.get!(AssignmentTask, assignment_id)
    assert binding.task_id == task.id

    omitted_replay =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments", Map.delete(params, "task_id"))
      |> json_response(201)

    assert omitted_replay == created
    assert Repo.get!(AssignmentTask, assignment_id).task_id == task.id

    replayed =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments", params)
      |> json_response(201)

    assert replayed == created
    replayed_binding = Repo.get!(AssignmentTask, assignment_id)
    assert replayed_binding.task_id == binding.task_id
    assert replayed_binding.inserted_at == binding.inserted_at

    conflict =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments", Map.put(params, "task_id", other_task.id))
      |> json_response(409)

    assert conflict["error"]["details"]["reason"] == "assignment_task_conflict"
    assert Repo.get!(AssignmentTask, assignment_id).task_id == task.id

    unbound_params = %{
      "assignment_id" => "survey-unbound",
      "phase" => "survey",
      "agent_type" => "epic-surveyor",
      "effort" => "medium",
      "snapshot_json" => "{}"
    }

    unbound =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments", unbound_params)
      |> json_response(201)

    refute Repo.get(AssignmentTask, unbound["assignment"]["id"])

    retroactive =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments", Map.put(unbound_params, "task_id", task.id))
      |> json_response(409)

    assert retroactive["error"]["details"]["reason"] == "assignment_task_conflict"
    refute Repo.get(AssignmentTask, unbound["assignment"]["id"])
  end

  test "invalid or cross-scope Task authority rolls back scoped assignments", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    other_project = create_project!(workspace, "cycle-task-binding-other")
    foreign_task = create_document!(workspace, other_project, "foreign")
    non_task = create_document!(workspace, project, "not-task", "paper")
    other_workspace = create_workspace!("cycle-task-binding-foreign-workspace")
    other_workspace_project = create_project!(other_workspace, "cycle-task-binding-foreign")

    other_workspace_task =
      create_document!(other_workspace, other_workspace_project, "foreign-workspace")

    epic_id = "cycle-task-authority-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["unit-1"])

    for {logical_id, task_id} <- [
          {"empty-task", ""},
          {"malformed-task", "not-a-uuid"},
          {"missing-task", Ecto.UUID.generate()},
          {"non-task", non_task.id},
          {"foreign-project-task", foreign_task.id},
          {"foreign-workspace-task", other_workspace_task.id}
        ] do
      rejected =
        scoped_conn()
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
      denied = scoped_conn() |> bearer(public_read) |> get(path)
      assert json_response(denied, 403)["error"]["code"] == "forbidden"

      allowed = scoped_conn() |> bearer(read) |> get(path) |> json_response(200)
      assert allowed["cycle_ledger"]["profile"] == "epic"
    end

    # NON-VACUOUS mount proof (arpss-cycle-api-publicread-followup): the
    # `code == "forbidden"` assertions above pass in BOTH states — the
    # controller seal (`authorize_cycle/3`) AND the `Plugs.PublicRead` mount on
    # `:cycle_api` each emit `forbidden`, so they cannot witness the mount. The
    # mount's ONLY observable change is the FLAT-path 403 MESSAGE, which flips
    # from the controller seal's "workspace access required" to the plug
    # canonical string. Assert the FLAT path ONLY: the scoped mirror already
    # rides `Plugs.PublicRead` (router.ex:187/:488) and its message never moves,
    # so diffing it would look like the mount did nothing (a second vacuity
    # trap). Unmount the plug from `:cycle_api` and EXACTLY this line reds.
    flat_denied = scoped_conn() |> bearer(public_read) |> get(flat)

    assert json_response(flat_denied, 403)["error"]["message"] ==
             "public-read tokens may only read published public documents"
  end

  # The singleton arm above only pins `permissions == ["public-read"]`. A token
  # minted `["public-read", "read"]` is the SAME tier but missed the old
  # list-equality clause in `authorize_cycle/3` and read the flat ledger, because
  # `:cycle_api` mounts `DeriveWorkspaceFromToken` and not `Plugs.PublicRead`.
  # Mutation-checked (review2-11697): reverting `authorize_cycle/3` to the
  # singleton pattern reds ONLY the FLAT-path 403 assertion below (200 leak).
  # The scoped path is defense-in-depth — `Plugs.PublicRead` on `:require_token`
  # (router.ex, `allowed_route?` whitelist) already 403s a public-read tier
  # there, so that arm stays green under the revert and is NOT the proof.
  test "a mixed-shape [public-read, read] token is refused exactly like the singleton", %{
    workspace: workspace,
    project: project,
    token: write_token
  } do
    epic_id = "cycle-public-read-mixed-#{System.unique_integer([:positive])}"
    flat = "/v1/cycles/#{epic_id}/wave-1"
    scoped = "/w/#{workspace.slug}/p/#{project.slug}" <> flat
    open_epic(flat, write_token, ["flat-unit"])
    open_epic(scoped, write_token, ["scoped-unit"])

    mixed = scoped_token!(workspace, ["public-read", "read"], "cycle-public-read-mixed")
    read = scoped_token!(workspace, ["read"], "cycle-mixed-control-read")

    for path <- [flat, scoped] do
      denied = scoped_conn() |> bearer(mixed) |> get(path)
      assert json_response(denied, 403)["error"]["code"] == "forbidden"

      # Positive controls: the seal is a tier test, not a blanket denial.
      allowed = scoped_conn() |> bearer(read) |> get(path) |> json_response(200)
      assert allowed["cycle_ledger"]["profile"] == "epic"

      admin = scoped_conn() |> bearer(write_token) |> get(path) |> json_response(200)
      assert admin["cycle_ledger"]["profile"] == "epic"
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

    assert scoped_conn()
           |> bearer(token)
           |> post(base <> "/open", %{
             "profile" => "epic",
             "inventory_json" => Jason.encode!(["unit-1"]),
             "scale_contract_json" => "{}"
           })
           |> json_response(201)

    wave_conflict =
      scoped_conn()
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
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments", assignment_params)
      |> json_response(201)

    replayed =
      scoped_conn()
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
      scoped_conn()
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

    completed_outcomes = %{
      "completed_unit_ids" => ["unit-1"],
      "stalled_unit_ids" => [],
      "excluded_unit_ids" => []
    }

    valid_payload = semantic_http_payload(base, "build-1", completed_outcomes)

    missing_receipts = %{
      "idempotency_key" => "terminal-build-1",
      "status" => "completed",
      "evidence" => "paper://build/1",
      "evidence_revision" => "rev-1",
      "payload_json" => Jason.encode!(completed_outcomes)
    }

    missing =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments/build-1/results", missing_receipts)
      |> json_response(422)

    assert missing["error"]["details"]["reason"] =~ "semantic_receipts_required"

    result_params =
      Map.put(
        missing_receipts,
        "payload_json",
        Jason.encode!(valid_payload)
      )

    assert scoped_conn()
           |> bearer(token)
           |> post(base <> "/assignments/build-1/results", result_params)
           |> json_response(201)

    idempotency_conflict =
      scoped_conn()
      |> bearer(token)
      |> post(
        base <> "/assignments/build-1/results",
        Map.put(
          result_params,
          "payload_json",
          Jason.encode!(
            semantic_http_payload(base, "build-1", %{
              "completed_unit_ids" => [],
              "stalled_unit_ids" => ["unit-1"],
              "excluded_unit_ids" => []
            })
          )
        )
      )
      |> json_response(409)

    assert idempotency_conflict["error"]["details"]["reason"] == "idempotency_conflict"

    terminal_conflict =
      scoped_conn()
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
      scoped_conn()
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
      scoped_conn()
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
      scoped_conn()
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
      scoped_conn()
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
      scoped_conn()
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
      scoped_conn()
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
      scoped_conn()
      |> Map.put(:host, "spoofed.cloud.example")
      |> bearer(token)
      |> get(base)
      |> json_response(200)

    assert local["authority"]["connection"]["execution_location"] == "local"
    assert local["authority"]["connection"]["server_origin"] == "http://127.0.0.1:4000"

    Application.put_env(:barkpark, :capabilities_base_url, "https://api.barkpark.cloud")

    remote =
      scoped_conn()
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
      assert scoped_conn()
             |> bearer(token)
             |> post(base <> "/assignments", params.(index))
             |> json_response(201)
    end

    assert scoped_conn()
           |> bearer(token)
           |> post(base <> "/assignments", params.(3))
           |> json_response(201)

    conflict =
      scoped_conn()
      |> bearer(token)
      |> post(
        base <> "/assignments",
        Map.put(params.(3), "snapshot_json", Jason.encode!(%{"changed" => true}))
      )
      |> json_response(409)

    assert conflict["error"]["details"]["reason"] == "assignment_conflict"

    exhausted =
      scoped_conn()
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

    scoped_conn()
    |> bearer(token)
    |> post(base <> "/seal", seal_params())
    |> json_response(200)

    too_wide =
      scoped_conn()
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
      scoped_conn()
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

  test "release-gate open with no correction_of returns 422, not 500", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "gate-open-missing-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["gate-unit"])

    body =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/release-gates/open", %{"idempotency_key" => "k1"})
      |> json_response(422)

    assert body["error"]["code"] == "validation_failed"
    assert body["error"]["details"]["reason"] =~ "correction_of_required"
  end

  test "release-paper stage with a non-object content returns 422, not 500", %{
    workspace: workspace,
    project: project,
    token: token
  } do
    epic_id = "gate-stage-scalar-#{System.unique_integer([:positive])}"
    base = "/w/#{workspace.slug}/p/#{project.slug}/v1/cycles/#{epic_id}/wave-1"
    open_epic(base, token, ["gate-unit"])

    body =
      scoped_conn()
      |> bearer(token)
      |> post(base <> "/release-gates/#{Ecto.UUID.generate()}/papers/author/stage", %{
        "content" => "not-an-object",
        "title" => "t"
      })
      |> json_response(422)

    assert body["error"]["code"] == "validation_failed"
    assert body["error"]["details"]["reason"] =~ "ambiguous_content"
  end

  defp open_epic(base, token, inventory) do
    scoped_conn()
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

    scoped_conn()
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

      scoped_conn()
      |> bearer(token)
      |> post(base <> "/assignments", %{
        "assignment_id" => id,
        "phase" => "experiment",
        "agent_type" => "legendary-experimenter",
        "effort" => "medium",
        "snapshot_json" => "{}"
      })
      |> json_response(201)

      scoped_conn()
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

    scoped_conn()
    |> bearer(token)
    |> post(base <> "/assignments", params)
    |> json_response(201)
  end

  defp create_http_epic_assignment(base, token, id) do
    scoped_conn()
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
        semantic_http_payload(base, assignment_id, payload)
      else
        payload
      end

    scoped_conn()
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

  defp semantic_http_payload(base, assignment_id, payload) do
    segments = base |> URI.parse() |> Map.fetch!(:path) |> String.split("/", trim: true)
    cycle_index = Enum.find_index(segments, &(&1 == "cycles"))
    epic_id = Enum.at(segments, cycle_index + 1)
    wave_key = Enum.at(segments, cycle_index + 2)

    assignment =
      Repo.one!(
        from assignment in Assignment,
          join: wave in Wave,
          on: wave.id == assignment.cycle_wave_id,
          where:
            assignment.assignment_id == ^assignment_id and wave.epic_id == ^epic_id and
              wave.wave_id == ^wave_key
      )

    task = ensure_semantic_http_task!(assignment)
    wave = Repo.get!(Wave, assignment.cycle_wave_id)

    outcomes =
      Map.merge(
        %{
          "completed_unit_ids" => [],
          "stalled_unit_ids" => [],
          "excluded_unit_ids" => []
        },
        stringify_keys(payload)
      )

    dispositions =
      Enum.reduce(
        [
          shipped: outcomes["completed_unit_ids"],
          stalled: outcomes["stalled_unit_ids"],
          excluded: outcomes["excluded_unit_ids"]
        ],
        %{},
        fn {disposition, ids}, acc ->
          Enum.reduce(ids, acc, &Map.put(&2, &1, Atom.to_string(disposition)))
        end
      )

    receipts =
      assignment.unit_ids
      |> Enum.sort()
      |> Enum.map(fn unit_id ->
        %{
          "assignment_id" => assignment.id,
          "ownership" => %{
            "assignment_id" => assignment.id,
            "assignment_key" => assignment.assignment_id,
            "cycle_wave_id" => assignment.cycle_wave_id,
            "snapshot_digest" => assignment.snapshot_digest,
            "workspace_id" => assignment.workspace_id,
            "project_id" => wave.project_id,
            "dataset_id" => task.dataset_id
          },
          "task_id" => task.id,
          "task_doc_id" => task.doc_id,
          "task_rev" => task.rev,
          "lifecycle_status" => "done",
          "criteria" => task.content["acceptance_criteria"],
          "claim" => %{
            "worker" => task.content["claim"]["worker"],
            "epoch" => task.content["claim"]["epoch"]
          },
          "unit_id" => unit_id,
          "disposition" => Map.fetch!(dispositions, unit_id)
        }
      end)

    Map.put(outcomes, "semantic_receipts", receipts)
  end

  defp ensure_semantic_http_task!(assignment) do
    case Repo.get(AssignmentTask, assignment.id) do
      %AssignmentTask{task_id: task_id} ->
        Repo.get!(Document, task_id)

      nil ->
        wave = Repo.get!(Wave, assignment.cycle_wave_id)
        project = Repo.get!(Barkpark.Tenancy.Project, wave.project_id)
        worker = "http-builder-#{assignment.assignment_id}"

        task =
          create_task!(
            Repo.get!(Barkpark.Tenancy.Workspace, assignment.workspace_id),
            project,
            worker
          )

        content = %{
          "kind" => "task",
          "lifecycle_status" => "done",
          "acceptance_criteria" => [
            %{
              "criterion" => "#{assignment.assignment_id} has HTTP evidence",
              "met" => true,
              "evidence" => "paper://http/#{assignment.assignment_id}"
            }
          ],
          "claim" => %{"worker" => worker, "epoch" => 1}
        }

        task = task |> Ecto.Changeset.change(content: content) |> Repo.update!()
        assert {:ok, _binding} = CycleFleet.bind_assignment_task(assignment, task.id)
        task
    end
  end

  defp get_cycle(base, token) do
    scoped_conn()
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

  defp create_task!(workspace, project, suffix),
    do: create_document!(workspace, project, suffix)

  defp create_document!(workspace, project, suffix, type \\ "task") do
    {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")

    %Document{}
    |> Document.changeset(%{
      doc_id: "drafts.cycle-http-task-#{suffix}-#{System.unique_integer([:positive])}",
      type: type,
      dataset: "production",
      title: "Cycle HTTP Task #{suffix}",
      status: "draft",
      content: %{"kind" => type, "lifecycle_status" => "open"},
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
