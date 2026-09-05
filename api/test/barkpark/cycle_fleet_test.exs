defmodule Barkpark.CycleFleetTestReleaseAdapter do
  @behaviour Barkpark.CycleFleet.ReleaseCaptureAdapter

  @impl true
  def capture(_request), do: {:error, :capture_not_used_by_seeded_gate}

  def public_smoke(request) do
    {:ok,
     %{
       "format" => "cycle-release-public-smoke-v1",
       "attempts" =>
         Enum.map(request["documents"], fn document ->
           %{
             "role" => document["role"],
             "document_id" => document["document_id"],
             "doc_id" => document["doc_id"],
             "url" => document["url"],
             "status" => 200,
             "redirect_count" => 0,
             "response_headers" => %{
               "content_type" => "text/html; charset=utf-8",
               "etag" => ~s("sha256:#{document["content_digest"]}"),
               "x_barkpark_paper_revision" => document["revision_id"]
             },
             "byte_count" => 256,
             "response_digest" =>
               :crypto.hash(:sha256, "#{document["role"]}-public-reader")
               |> Base.encode16(case: :lower),
             "deployment_digest" => request["deployment_digest"],
             "verdict" => "pass"
           }
         end)
     }}
  end
end

defmodule Barkpark.CycleFleetTest do
  use Barkpark.DataCase, async: false

  unless Code.ensure_loaded?(Barkpark.Repo.Migrations.CreateCycleWaves) do
    Code.require_file(
      Path.expand("../../priv/repo/migrations/20260715000500_create_cycle_waves.exs", __DIR__)
    )
  end

  unless Code.ensure_loaded?(Barkpark.Repo.Migrations.RejectPaddedCycleUnitIds) do
    Code.require_file(
      Path.expand(
        "../../priv/repo/migrations/20260715000600_reject_padded_cycle_unit_ids.exs",
        __DIR__
      )
    )
  end

  unless Code.ensure_loaded?(Barkpark.Repo.Migrations.AddCycleCorrectionQuarantinePromotion) do
    Code.require_file(
      Path.expand(
        "../../priv/repo/migrations/20260719010000_add_cycle_correction_quarantine_promotion.exs",
        __DIR__
      )
    )
  end

  alias Barkpark.CycleFleet
  alias Barkpark.Content.{Document, Revision}
  alias Barkpark.CycleFleet.{AssignmentTask, BuildPlan, Profile, Wave}
  alias Barkpark.CycleFleet.ReleaseGate
  alias Barkpark.CycleFleet.ReleaseGate.{Consumption, PaperCandidate}
  alias Barkpark.EpicFleet.{Assignment, Result}
  alias Barkpark.Tenancy

  setup do
    {workspace, project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    scope = %{
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: "cycle-#{System.unique_integer([:positive])}",
      wave_id: "wave-1"
    }

    %{scope: scope}
  end

  describe "profiles" do
    test "Epic stays fixed and Legendary derives builders from proven capacity" do
      assert {:ok, epic} = Profile.plan(:epic, %{})
      assert epic.build.planned == 3
      assert epic.survey.effort == "medium"
      assert epic.verify.effort == "medium"
      assert epic.build.effort == "high"
      assert epic.review.effort == "high"
      refute Map.has_key?(epic, :experiment)

      assert {:ok, legendary_floor} =
               Profile.plan(:legendary, %{unit_count: 30, proven_batch_capacity: 10})

      assert legendary_floor.build == %{
               agent_type: "legendary-builder",
               effort: "medium",
               planned: 15
             }

      assert legendary_floor.experiment.planned == 15
      assert legendary_floor.experiment.effort == "medium"
      assert legendary_floor.review.effort == "high"

      assert {:ok, legendary_scaled} =
               Profile.plan(:legendary, %{unit_count: 151, proven_batch_capacity: 7})

      assert legendary_scaled.build.planned == 22
      assert {:error, :proven_batch_capacity} = Profile.plan(:legendary, %{unit_count: 10})
    end

    test "promotion admission reads phase effort from the authoritative Paper" do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT pg_get_functiondef('barkpark_validate_cycle_correction()'::regprocedure)"
        )

      assert definition =~ "fleet_phase.value->>'effort' AS expected_effort"

      assert definition =~
               ~r/actual\.effort IS DISTINCT FROM\s+expected\.expected_effort/

      refute definition =~
               ~r/actual\.effort IS DISTINCT FROM\s+CASE WHEN expected\.phase IN \('build', 'review'\)/

      assert definition =~
               ~r/model_reasoning_effort'\) IS DISTINCT FROM\s+CASE WHEN expected\.phase IN \('build', 'review'\)/
    end

    test "promotion admission preserves the frozen live-authority digest contract" do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT pg_get_functiondef('barkpark_validate_cycle_correction()'::regprocedure)"
        )

      assert definition =~
               "block->'cycle_ledger'->>'live_authority_digest' ~ '^[0-9a-f]{64}$'"

      refute definition =~
               ~r/live_authority_digest' =\s+barkpark_jsonb_canonical_digest/
    end
  end

  describe "durable wave contracts" do
    test "Legendary rejects empty, one-unit, and sub-floor inventories", %{scope: scope} do
      for count <- [0, 1, 14] do
        inventory = Enum.map(1..count//1, &%{unit_id: "unit-#{&1}"})

        assert {:error, :invalid_scale_contract} =
                 CycleFleet.open_wave(
                   Map.merge(scope, %{
                     profile: "legendary",
                     inventory: inventory,
                     scale_contract: scale_contract(count)
                   })
                 )
      end
    end

    test "Legendary rejects blank or padded inventory IDs instead of counting them", %{
      scope: scope
    } do
      for invalid_id <- ["   ", " padded-unit "] do
        inventory = Enum.map(1..14, &%{unit_id: "unit-#{&1}"}) ++ [%{unit_id: invalid_id}]

        assert {:error, :invalid_inventory} =
                 CycleFleet.open_wave(
                   Map.merge(scope, %{
                     profile: "legendary",
                     inventory: inventory,
                     scale_contract: scale_contract(15)
                   })
                 )
      end
    end

    test "database rejects malformed wave inventory and the Legendary inventory floor", %{
      scope: scope
    } do
      for {inventory, message} <- [
            {[%{"unit_id" => " padded-unit "}], ~r/unpadded non-empty unit_id strings/},
            {[%{"unit_id" => ""}], ~r/unpadded non-empty unit_id strings/},
            {[%{"unit_id" => 1}], ~r/unpadded non-empty unit_id strings/},
            {[%{"other" => "unit-1"}], ~r/unpadded non-empty unit_id strings/},
            {[%{"unit_id" => "unit-1"}, %{"unit_id" => "unit-1"}], ~r/must be unique/}
          ] do
        assert_raise Postgrex.Error, message, fn ->
          raw_insert_wave!(
            %{scope | wave_id: "raw-invalid-#{System.unique_integer([:positive])}"},
            "epic",
            inventory
          )
        end
      end

      assert_raise Postgrex.Error, ~r/must contain at least 15 entries/, fn ->
        raw_insert_wave!(
          %{scope | wave_id: "raw-legendary-under-floor"},
          "legendary",
          Enum.map(1..14, &%{"unit_id" => "unit-#{&1}"})
        )
      end

      assert %{rows: [[epic_id]]} =
               raw_insert_wave!(
                 %{scope | wave_id: "raw-valid-epic"},
                 "epic",
                 [%{"unit_id" => "unit-1"}]
               )

      assert %{rows: [[legendary_id]]} =
               raw_insert_wave!(
                 %{scope | wave_id: "raw-valid-legendary"},
                 "legendary",
                 Enum.map(1..15, &%{"unit_id" => "unit-#{&1}"})
               )

      assert Repo.get!(Wave, Ecto.UUID.load!(epic_id))
      assert Repo.get!(Wave, Ecto.UUID.load!(legendary_id))
    end

    test "rolling back 00600 preserves the base inventory boundary", %{scope: scope} do
      migration = Barkpark.Repo.Migrations.RejectPaddedCycleUnitIds

      assert :ok =
               Ecto.Migrator.down(
                 Repo,
                 20_260_715_000_600,
                 migration,
                 log: false,
                 migration_lock: false
               )

      assert %{rows: [["aa_cycle_waves_validate_inventory"]]} =
               Repo.query!(
                 """
                 SELECT trigger_name
                 FROM information_schema.triggers
                 WHERE event_object_table = 'cycle_waves'
                   AND trigger_name = 'aa_cycle_waves_validate_inventory'
                 LIMIT 1
                 """,
                 []
               )

      assert_raise Postgrex.Error, ~r/unpadded non-empty unit_id strings/, fn ->
        raw_insert_wave!(
          %{scope | wave_id: "base-boundary-after-00600-down"},
          "epic",
          [%{"unit_id" => " padded-unit "}]
        )
      end
    end

    test "00600 refuses to retrofit invalid existing inventory", %{scope: scope} do
      migration = Barkpark.Repo.Migrations.RejectPaddedCycleUnitIds

      assert :ok =
               Ecto.Migrator.down(
                 Repo,
                 20_260_715_000_600,
                 migration,
                 log: false,
                 migration_lock: false
               )

      Repo.query!("ALTER TABLE cycle_waves DISABLE TRIGGER aa_cycle_waves_validate_inventory")

      raw_insert_wave!(
        %{scope | wave_id: "invalid-before-00600-up"},
        "epic",
        [%{"unit_id" => " padded-unit "}]
      )

      Repo.query!("ALTER TABLE cycle_waves ENABLE TRIGGER aa_cycle_waves_validate_inventory")

      assert_raise Postgrex.Error, ~r/cannot install cycle wave inventory retrofit/, fn ->
        Ecto.Migrator.up(
          Repo,
          20_260_715_000_600,
          migration,
          log: false,
          migration_lock: false
        )
      end

      assert %{rows: []} =
               Repo.query!(
                 """
                 SELECT trigger_name
                 FROM information_schema.triggers
                 WHERE event_object_table = 'cycle_waves'
                   AND trigger_name = 'aa_cycle_waves_validate_inventory_00600'
                 """,
                 []
               )
    end

    test "migration rollback remains available only while the cycle tables are unused", %{
      scope: scope
    } do
      migration = Barkpark.Repo.Migrations.CreateCycleWaves
      baseline = migration.rollback_blockers()

      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 1))
      after_wave = migration.rollback_blockers()
      refute after_wave.safe?
      assert after_wave.cycle_waves == baseline.cycle_waves + 1
      assert after_wave.cycle_build_plans == baseline.cycle_build_plans
      assert after_wave.cycle_bound_assignments == baseline.cycle_bound_assignments

      complete_experiments(scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(2))

      after_plan = migration.rollback_blockers()
      refute after_plan.safe?
      assert after_plan.cycle_waves == baseline.cycle_waves + 1
      assert after_plan.cycle_build_plans == baseline.cycle_build_plans + 1
      assert after_plan.cycle_bound_assignments == baseline.cycle_bound_assignments + 15
    end

    test "Legendary open freezes the complete scale contract and seal waits for Pilot", %{
      scope: scope
    } do
      attrs = legendary_wave_attrs(scope, 30)
      assert {:ok, wave} = CycleFleet.open_wave(attrs)
      assert wave.profile == "legendary"

      assert wave.plan["build"] == %{
               "agent_type" => "legendary-builder",
               "effort" => "medium",
               "planned" => 15,
               "provisional" => true
             }

      assert wave.scale_contract == stringify_keys(scale_contract(30))
      assert length(wave.inventory) == 30

      assert {:ok, replay} = CycleFleet.open_wave(attrs)
      assert replay.id == wave.id

      assert {:error, :wave_conflict} =
               attrs
               |> Map.put(
                 :inventory,
                 Enum.map(1..15, &%{unit_id: "different-#{&1}"})
               )
               |> Map.put(:scale_contract, scale_contract(15))
               |> CycleFleet.open_wave()

      assert {:error, :experiment_assignments_incomplete} =
               CycleFleet.seal_build_plan(scope, build_plan_attrs(10))

      complete_experiments(scope)

      assert {:ok, build_plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(10))
      assert build_plan.plan["build"]["planned"] == 15
      assert build_plan.golden_fixtures == ["paper://fixtures/bad", "paper://fixtures/good"]
      assert build_plan.quality_rubric == stringify_keys(quality_rubric())

      assert {:ok, replayed_plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(10))
      assert replayed_plan.id == build_plan.id

      assert {:error, :build_plan_conflict} =
               CycleFleet.seal_build_plan(scope, %{build_plan_attrs(10) | chosen_format: "other"})

      wave_query =
        from wave in Wave,
          where:
            wave.workspace_id == ^scope.workspace_id and wave.project_id == ^scope.project_id and
              wave.epic_id == ^scope.epic_id

      plan_query =
        from plan in BuildPlan,
          join: wave in Wave,
          on: wave.id == plan.wave_id,
          where:
            wave.workspace_id == ^scope.workspace_id and wave.project_id == ^scope.project_id and
              wave.epic_id == ^scope.epic_id

      assert Repo.aggregate(wave_query, :count) == 1
      assert Repo.aggregate(plan_query, :count) == 1
    end

    test "assignments require a wave and Legendary build requires a seal", %{scope: scope} do
      assert {:error, :wave_not_found} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "survey-early", "survey", "epic-surveyor", [])
               )

      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 1))

      assert {:error, :build_plan_not_sealed} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "build-1", "build", "legendary-builder", ["unit-1"])
               )

      assert {:error, :agent_type_not_in_profile} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "experiment-1", "experiment", "epic-verifier", [])
               )
    end

    test "profile effort is exact for Epic and Legendary assignments", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      for {phase, agent_type, wrong_effort} <- [
            {"survey", "epic-surveyor", "high"},
            {"verify", "epic-verifier", "high"},
            {"build", "epic-builder", "medium"},
            {"review", "code-reviewer", "medium"}
          ] do
        assert {:error, :effort_not_in_profile} =
                 scope
                 |> assignment_attrs("epic-wrong-#{phase}", phase, agent_type, [])
                 |> Map.put(:effort, wrong_effort)
                 |> CycleFleet.create_assignment()
      end

      legendary_scope = %{scope | wave_id: "wave-legendary"}
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(legendary_scope, 1))

      assert {:error, :effort_not_in_profile} =
               legendary_scope
               |> assignment_attrs(
                 "legendary-wrong-experiment",
                 "experiment",
                 "legendary-experimenter",
                 []
               )
               |> Map.put(:effort, "high")
               |> CycleFleet.create_assignment()

      complete_experiments(legendary_scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(legendary_scope, build_plan_attrs(1))

      for {phase, agent_type, wrong_effort} <- [
            {"survey", "epic-surveyor", "high"},
            {"verify", "epic-verifier", "high"},
            {"build", "legendary-builder", "high"},
            {"review", "code-reviewer", "medium"}
          ] do
        assert {:error, :effort_not_in_profile} =
                 legendary_scope
                 |> assignment_attrs("legendary-wrong-#{phase}", phase, agent_type, [])
                 |> Map.put(:effort, wrong_effort)
                 |> CycleFleet.create_assignment()
      end
    end

    test "logical replacement ids resolve to the cycle assignment row UUID", %{scope: scope} do
      assert {:ok, wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      assert {:ok, original} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "build-1", "build", "epic-builder", ["unit-1"])
               )

      assert {:ok, _result} =
               complete_result(original, "failed-build-1", "failed", %{})

      replacement_attrs =
        scope
        |> assignment_attrs("build-1-retry", "build", "epic-builder", ["unit-1"])
        |> Map.put(:replaces_assignment_id, "build-1")

      assert {:ok, replacement} = CycleFleet.create_assignment(replacement_attrs)
      assert replacement.replaces_assignment_id == original.id
      assert CycleFleet.get_assignment(scope, "build-1-retry").id == replacement.id
      refute replacement.id == original.id
      assert replacement.cycle_wave_id == wave.id
      assert replacement.unit_ids == original.unit_ids
      assert replacement.inventory_digest == original.inventory_digest

      assert {:ok, replacement_replay} = CycleFleet.create_assignment(replacement_attrs)

      assert CycleFleet.assignment_attribution(replacement_replay) ==
               CycleFleet.assignment_attribution(replacement)

      assert {:error, :replacement_not_found} =
               replacement_attrs
               |> Map.put(:assignment_id, "build-2-retry")
               |> Map.put(:replaces_assignment_id, "missing-logical-id")
               |> CycleFleet.create_assignment()
    end

    test "project identity separates otherwise identical cycle scopes", %{scope: scope} do
      {workspace, default_project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      other_project = Barkpark.TenancyFixtures.create_project!(workspace, "cycle-other")

      first = %{scope | project_id: default_project.id}
      second = %{scope | project_id: other_project.id}

      assert {:ok, first_wave} = CycleFleet.open_wave(epic_wave_attrs(first, ["unit-1"]))
      assert {:ok, second_wave} = CycleFleet.open_wave(epic_wave_attrs(second, ["unit-2"]))
      refute first_wave.id == second_wave.id
      assert CycleFleet.get_wave(first).inventory == [%{"unit_id" => "unit-1"}]
      assert CycleFleet.get_wave(second).inventory == [%{"unit_id" => "unit-2"}]
    end

    test "a project id cannot cross its workspace boundary", %{scope: scope} do
      foreign_workspace = Barkpark.TenancyFixtures.create_workspace!("cycle-foreign")
      foreign_project = Barkpark.TenancyFixtures.create_project!(foreign_workspace, "foreign")
      mismatched = %{scope | project_id: foreign_project.id}
      {:ok, epic_plan} = Profile.opening_plan("epic")

      assert {:error, :project_scope_mismatch} =
               CycleFleet.open_wave(epic_wave_attrs(mismatched, ["unit-1"]))

      attrs = %{
        workspace_id: scope.workspace_id,
        project_id: foreign_project.id,
        epic_id: scope.epic_id,
        wave_id: scope.wave_id,
        profile: "epic",
        inventory: [%{"unit_id" => "unit-1"}],
        inventory_digest: CycleFleet.digest([%{"unit_id" => "unit-1"}]),
        plan: stringify_keys(epic_plan),
        plan_digest: CycleFleet.digest(epic_plan),
        experiment_contract: %{},
        scale_contract: %{}
      }

      assert {:error, changeset} = attrs |> Wave.insert_changeset() |> Repo.insert()
      assert "does not exist" in errors_on(changeset).project_id
    end

    test "workspace and project teardown remove tenant-owned ledgers without opening direct deletes" do
      workspace = Barkpark.TenancyFixtures.create_workspace!("cycle-teardown")
      project = Barkpark.TenancyFixtures.create_project!(workspace, "cycle-teardown")

      scope = %{
        workspace_id: workspace.id,
        project_id: project.id,
        epic_id: "cycle-teardown",
        wave_id: "wave-1"
      }

      assert {:ok, wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 1))
      complete_experiments(scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(1))
      chain = create_retry_chain(scope, "legendary-builder")

      assert {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")

      task =
        %Document{}
        |> Document.changeset(%{
          doc_id: "drafts.cycle-teardown-task",
          type: "task",
          dataset: "production",
          title: "Cycle teardown task",
          status: "draft",
          content: %{
            "kind" => "task",
            "acceptance_criteria" => [
              %{
                "criterion" => "the fixture states its bar",
                "met" => true,
                "evidence" => "fixture"
              }
            ],
            "lifecycle_status" => "open"
          },
          rev: Ecto.UUID.generate(),
          workspace_id: workspace.id,
          project_id: project.id,
          dataset_id: dataset.id
        })
        |> Repo.insert!()

      assert {:ok, binding} = CycleFleet.bind_assignment_task(hd(chain), task.id)
      assert Repo.get!(AssignmentTask, binding.assignment_id)

      assert Enum.map(chain, &CycleFleet.get_result/1) |> Enum.all?(&match?(%Result{}, &1))

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM cycle_waves WHERE id = $1", [Ecto.UUID.dump!(wave.id)])
      end

      assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
      refute Repo.get(Wave, wave.id)
      refute Repo.get(AssignmentTask, binding.assignment_id)
      refute Repo.get(Document, task.id)
      assert Repo.aggregate(BuildPlan, :count, :id) == 0

      refute Repo.exists?(
               from assignment in Assignment,
                 where: assignment.workspace_id == ^workspace.id
             )

      refute Repo.exists?(
               from result in Result,
                 join: assignment in Assignment,
                 on: result.assignment_id == assignment.id,
                 where: assignment.workspace_id == ^workspace.id
             )

      Enum.each(chain, fn assignment ->
        refute Repo.get(Assignment, assignment.id)
        refute Repo.get_by(Result, assignment_id: assignment.id)
      end)
    end

    test "session teardown setting cannot spoof a direct append-only delete", %{scope: scope} do
      assert {:ok, wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      Repo.query!(
        "SELECT set_config('barkpark.cycle_teardown_workspace', $1, true)",
        [scope.workspace_id]
      )

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM cycle_waves WHERE id = $1", [Ecto.UUID.dump!(wave.id)])
      end
    end

    test "project teardown removes only that project's cycle ledger" do
      workspace = Barkpark.TenancyFixtures.create_workspace!("cycle-project-teardown")
      project = Barkpark.TenancyFixtures.create_project!(workspace, "doomed")
      survivor = Barkpark.TenancyFixtures.create_project!(workspace, "survivor")

      doomed_scope = %{
        workspace_id: workspace.id,
        project_id: project.id,
        epic_id: "project-teardown",
        wave_id: "wave-1"
      }

      survivor_scope = %{doomed_scope | project_id: survivor.id}
      assert {:ok, doomed_wave} = CycleFleet.open_wave(epic_wave_attrs(doomed_scope, ["unit-1"]))

      chain = create_retry_chain(doomed_scope, "epic-builder")

      assert {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")

      task =
        %Document{}
        |> Document.changeset(%{
          doc_id: "drafts.project-teardown-task",
          type: "task",
          dataset: "production",
          title: "Project teardown task",
          status: "draft",
          content: %{
            "kind" => "task",
            "acceptance_criteria" => [
              %{
                "criterion" => "the fixture states its bar",
                "met" => true,
                "evidence" => "fixture"
              }
            ],
            "lifecycle_status" => "open"
          },
          rev: Ecto.UUID.generate(),
          workspace_id: workspace.id,
          project_id: project.id,
          dataset_id: dataset.id
        })
        |> Repo.insert!()

      assert {:ok, binding} = CycleFleet.bind_assignment_task(hd(chain), task.id)
      assert Repo.get!(AssignmentTask, binding.assignment_id)

      assert Enum.map(chain, &CycleFleet.get_result/1) |> Enum.all?(&match?(%Result{}, &1))

      assert {:ok, survivor_wave} =
               CycleFleet.open_wave(epic_wave_attrs(survivor_scope, ["unit-2"]))

      assert {:ok, _project} = Repo.delete(project)
      refute Repo.get(Wave, doomed_wave.id)
      refute Repo.get(AssignmentTask, binding.assignment_id)
      refute Repo.get(Document, task.id)
      assert Repo.get(Wave, survivor_wave.id)
      assert Tenancy.get_workspace_by_id(workspace.id)

      Enum.each(chain, fn assignment ->
        refute Repo.get(Assignment, assignment.id)
        refute Repo.get_by(Result, assignment_id: assignment.id)
      end)
    end

    test "legacy published Papers deterministically backfill revision ownership and pointers", %{
      scope: scope
    } do
      dataset =
        Repo.one!(
          from dataset in Barkpark.Tenancy.Dataset,
            where: dataset.project_id == ^scope.project_id and dataset.slug == "production"
        )

      document =
        %Document{}
        |> Document.changeset(%{
          doc_id: "legacy-paper-backfill",
          type: "paper",
          dataset: "production",
          dataset_id: dataset.id,
          workspace_id: scope.workspace_id,
          project_id: scope.project_id,
          title: "Legacy Paper",
          status: "published",
          content: %{"blocks" => [%{"type" => "paragraph", "text" => "released"}]},
          rev: Ecto.UUID.generate()
        })
        |> Repo.insert!()

      draft_document =
        %Document{}
        |> Document.changeset(%{
          doc_id: "drafts.#{document.doc_id}",
          type: document.type,
          dataset: document.dataset,
          dataset_id: document.dataset_id,
          workspace_id: document.workspace_id,
          project_id: document.project_id,
          title: "Legacy Paper Draft",
          status: "draft",
          content: %{"blocks" => [%{"type" => "paragraph", "text" => "draft-only"}]},
          rev: Ecto.UUID.generate()
        })
        |> Repo.insert!()

      base_time =
        DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:microsecond)

      insert_legacy_revision = fn action, content, seconds ->
        %Revision{}
        |> Revision.changeset(%{
          doc_id: document.doc_id,
          type: document.type,
          dataset: document.dataset,
          dataset_id: document.dataset_id,
          workspace_id: document.workspace_id,
          project_id: document.project_id,
          title: document.title,
          status: document.status,
          action: action,
          content: content
        })
        |> Ecto.Changeset.put_change(:inserted_at, DateTime.add(base_time, seconds, :second))
        |> Repo.insert!()
      end

      _older_exact = insert_legacy_revision.("publish", document.content, 1)
      newest_exact = insert_legacy_revision.("update", document.content, 2)
      newer_mismatch = insert_legacy_revision.("update", %{"blocks" => []}, 3)

      draft_revision =
        %Revision{}
        |> Revision.changeset(%{
          doc_id: document.doc_id,
          type: draft_document.type,
          dataset: draft_document.dataset,
          dataset_id: draft_document.dataset_id,
          workspace_id: draft_document.workspace_id,
          project_id: draft_document.project_id,
          title: draft_document.title,
          status: draft_document.status,
          action: "update",
          content: draft_document.content
        })
        |> Ecto.Changeset.put_change(:inserted_at, DateTime.add(base_time, 4, :second))
        |> Repo.insert!()

      assert Repo.get!(Document, document.id).current_revision_id == nil
      assert Repo.get!(Document, document.id).released_revision_id == nil

      Repo.query!("ALTER TABLE revisions DISABLE TRIGGER revisions_immutable")

      Repo.query!("""
      WITH bindings AS (
        SELECT revision.id AS revision_id, (
          SELECT document.id
          FROM documents document
          WHERE revision.doc_id = CASE
              WHEN left(document.doc_id, 7) = 'drafts.' THEN substr(document.doc_id, 8)
              ELSE document.doc_id
            END AND
            revision.type = document.type AND revision.dataset_id = document.dataset_id AND
            revision.workspace_id = document.workspace_id AND
            revision.project_id IS NOT DISTINCT FROM document.project_id AND
            revision.title IS NOT DISTINCT FROM document.title AND
            revision.status IS NOT DISTINCT FROM document.status AND
            revision.content IS NOT DISTINCT FROM document.content
          ORDER BY CASE WHEN document.doc_id = revision.doc_id THEN 0 ELSE 1 END, document.id
          LIMIT 1
        ) AS document_id
        FROM revisions revision
        WHERE revision.document_id IS NULL
      )
      UPDATE revisions revision
      SET document_id = bindings.document_id
      FROM bindings
      WHERE revision.id = bindings.revision_id AND bindings.document_id IS NOT NULL
      """)

      Repo.query!("ALTER TABLE revisions ENABLE TRIGGER revisions_immutable")

      Repo.query!(
        """
        UPDATE documents document
        SET current_revision_id = (
          SELECT revision.id FROM revisions revision
          WHERE revision.document_id = document.id AND revision.content = document.content AND
            revision.title IS NOT DISTINCT FROM document.title AND revision.status = document.status
          ORDER BY revision.inserted_at DESC, revision.id DESC LIMIT 1
        ), released_revision_id = (
          SELECT revision.id FROM revisions revision
          WHERE revision.document_id = document.id AND revision.status = 'published' AND
            revision.content = document.content AND
            revision.title IS NOT DISTINCT FROM document.title
          ORDER BY revision.inserted_at DESC, revision.id DESC LIMIT 1
        )
        WHERE document.id = $1
        """,
        [Ecto.UUID.dump!(document.id)]
      )

      reloaded = Repo.get!(Document, document.id)
      assert reloaded.current_revision_id == newest_exact.id
      assert reloaded.released_revision_id == newest_exact.id
      assert Repo.get!(Revision, newest_exact.id).document_id == document.id
      assert Repo.get!(Revision, draft_revision.id).document_id == draft_document.id
      assert Repo.get!(Revision, newer_mismatch.id).document_id == nil

      assert Repo.aggregate(
               from(revision in Revision, where: revision.document_id == ^document.id),
               :count
             ) == 2
    end

    test "quarantine promotion migration refuses rollback after immutable correction history", %{
      scope: scope
    } do
      assert {:ok, wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      Repo.query!(
        """
        INSERT INTO cycle_correction_roots
          (root_wave_id, workspace_id, project_id, epic_id, inserted_at)
        VALUES ($1, $2, $3, $4, now())
        """,
        [
          Ecto.UUID.dump!(wave.id),
          Ecto.UUID.dump!(scope.workspace_id),
          Ecto.UUID.dump!(scope.project_id),
          scope.epic_id
        ]
      )

      assert_raise Postgrex.Error,
                   ~r/cannot roll back quarantine-promotion-v1 after immutable correction history exists/,
                   fn ->
                     Ecto.Migrator.down(
                       Repo,
                       20_260_719_010_000,
                       Barkpark.Repo.Migrations.AddCycleCorrectionQuarantinePromotion,
                       log: false,
                       migration_lock: false
                     )
                   end
    end

    test "database keeps frozen waves and build plans append-only", %{scope: scope} do
      {:ok, wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 1))
      complete_experiments(scope)
      {:ok, build_plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(1))

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE cycle_waves SET profile = 'epic' WHERE id = $1", [
          Ecto.UUID.dump!(wave.id)
        ])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE cycle_build_plans SET chosen_format = 'tampered' WHERE id = $1", [
          Ecto.UUID.dump!(build_plan.id)
        ])
      end
    end

    test "phase capacity is fixed and experiments close at seal", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 1))
      complete_experiments(scope)

      assert {:error, :phase_assignment_capacity_exhausted} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "experiment-overflow",
                   "experiment",
                   "legendary-experimenter",
                   []
                 )
               )

      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(1))

      assert {:error, :experiment_phase_sealed} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "experiment-after-seal",
                   "experiment",
                   "legendary-experimenter",
                   []
                 )
               )
    end

    test "full phase capacity admits immutable replay but rejects conflicts and new ids", %{
      scope: scope
    } do
      assert {:ok, wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      assignments =
        for index <- 1..3 do
          attrs =
            assignment_attrs(
              scope,
              "review-#{index}",
              "review",
              "code-reviewer",
              []
            )

          assert {:ok, assignment} = CycleFleet.create_assignment(attrs)
          {attrs, assignment}
        end

      {replay_attrs, original} = List.last(assignments)
      assert {:ok, replay} = CycleFleet.create_assignment(replay_attrs)
      assert replay.id == original.id

      assert {:error, :assignment_conflict} =
               replay_attrs
               |> put_in([:snapshot, :unit_ids], ["changed"])
               |> CycleFleet.create_assignment()

      assert {:error, :phase_assignment_capacity_exhausted} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "review-4", "review", "code-reviewer", [])
               )

      assert_raise Postgrex.Error, ~r/epic_assignments_cycle_assignment_index/, fn ->
        raw_insert_assignment!(wave, scope, %{
          assignment_id: original.assignment_id,
          phase: original.phase,
          agent_type: original.agent_type,
          effort: original.effort,
          snapshot: original.snapshot,
          replaces_assignment_id: nil
        })
      end
    end

    test "retrieval attribution is durable, project-scoped, replay-stable, and append-only" do
      {workspace, first_project} = Barkpark.TenancyFixtures.ensure_default_scope!()
      second_project = Barkpark.TenancyFixtures.create_project!(workspace, "attribution-other")

      common = %{
        workspace_id: workspace.id,
        epic_id: "retrieval-attribution",
        wave_id: "wave-1"
      }

      first = Map.put(common, :project_id, first_project.id)
      second = Map.put(common, :project_id, second_project.id)
      assert {:ok, first_wave} = CycleFleet.open_wave(epic_wave_attrs(first, ["unit-1"]))
      assert {:ok, second_wave} = CycleFleet.open_wave(epic_wave_attrs(second, ["unit-2"]))

      attrs = assignment_attrs(first, "build-1", "build", "epic-builder", ["unit-1"])
      assert {:ok, assignment} = CycleFleet.create_assignment(attrs)
      assert assignment.cycle_wave_id == first_wave.id
      assert assignment.unit_ids == ["unit-1"]
      assert assignment.inventory_digest == first_wave.inventory_digest
      assert assignment.snapshot_digest == CycleFleet.digest(attrs.snapshot)

      expected = %{
        cycle_assignment_id: assignment.id,
        cycle_wave_id: first_wave.id,
        assignment_id: "build-1",
        unit_ids: ["unit-1"],
        inventory_digest: first_wave.inventory_digest,
        snapshot_digest: assignment.snapshot_digest
      }

      assert CycleFleet.assignment_attributions(first) == [expected]
      assert CycleFleet.assignment_attributions(second) == []
      assert {:ok, %{assignment_attributions: [^expected]}} = CycleFleet.projection(first)

      assert {:ok, replay} = CycleFleet.create_assignment(attrs)
      assert CycleFleet.assignment_attribution(replay) == expected

      assert {:error, :assignment_conflict} =
               attrs
               |> put_in([:snapshot, :changed], true)
               |> CycleFleet.create_assignment()

      assert {:ok, other_assignment} =
               CycleFleet.create_assignment(
                 assignment_attrs(second, "build-1", "build", "epic-builder", ["unit-2"])
               )

      refute other_assignment.id == assignment.id
      assert other_assignment.cycle_wave_id == second_wave.id
      assert other_assignment.inventory_digest == second_wave.inventory_digest
      assert CycleFleet.assignment_attributions(first) == [expected]

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!(
          "UPDATE epic_assignments SET unit_ids = ARRAY['unit-2'] WHERE id = $1",
          [Ecto.UUID.dump!(assignment.id)]
        )
      end

      assert CycleFleet.assignment_attributions(first) == [expected]
    end

    test "Review capacity is immutable for both cycle profiles", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      for index <- 1..3 do
        assert {:ok, _assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(
                     scope,
                     "epic-review-#{index}",
                     "review",
                     "code-reviewer",
                     []
                   )
                 )
      end

      assert {:error, :phase_assignment_capacity_exhausted} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "epic-review-4",
                   "review",
                   "code-reviewer",
                   []
                 )
               )

      legendary_scope = %{scope | wave_id: "wave-legendary-review"}
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(legendary_scope, 1))

      for index <- 1..15 do
        assert {:ok, _assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(
                     legendary_scope,
                     "legendary-review-#{index}",
                     "review",
                     "code-reviewer",
                     []
                   )
                 )
      end

      assert {:error, :phase_assignment_capacity_exhausted} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   legendary_scope,
                   "legendary-review-16",
                   "review",
                   "code-reviewer",
                   []
                 )
               )
    end

    test "sealed proven capacity rejects oversized build shards", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 2))
      complete_experiments(scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(1))

      assert {:error, :proven_batch_capacity_exceeded} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "build-too-wide",
                   "build",
                   "legendary-builder",
                   ["unit-1", "unit-2"]
                 )
               )
    end

    test "Build assignment ownership is non-empty, typed, unique, bounded, and inventoried", %{
      scope: scope
    } do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 15))
      complete_experiments(scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(2))

      for {units, reason} <- [
            {[], :invalid_build_unit_ids},
            {["unit-1", ""], :invalid_build_unit_ids},
            {["unit-1", " unit-2"], :invalid_build_unit_ids},
            {["unit-1", 2], :invalid_build_unit_ids},
            {["unit-1", "unit-1"], :duplicate_build_unit_ids},
            {["unit-unknown"], :build_unit_not_in_inventory}
          ] do
        assert {:error, ^reason} =
                 CycleFleet.create_assignment(
                   assignment_attrs(
                     scope,
                     "invalid-#{inspect(reason)}",
                     "build",
                     "legendary-builder",
                     units
                   )
                 )
      end

      assert {:ok, assignment} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "one-unit-build",
                   "build",
                   "legendary-builder",
                   ["unit-1"]
                 )
               )

      assert assignment.snapshot["unit_ids"] == ["unit-1"] or
               assignment.snapshot[:unit_ids] == ["unit-1"]

      assert assignment.unit_ids == ["unit-1"]
      assert assignment.inventory_digest == CycleFleet.get_wave(scope).inventory_digest
    end

    test "completed Build results exactly partition owned units with typed outcome lists", %{
      scope: scope
    } do
      assert {:ok, _wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1", "unit-2"]))

      assert {:ok, assignment} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "build-partition",
                   "build",
                   "epic-builder",
                   ["unit-1", "unit-2"]
                 )
               )

      for {key, payload, reason} <- [
            {"missing-list", %{completed_unit_ids: ["unit-1", "unit-2"]},
             :invalid_build_unit_ids},
            {"partial", typed_outcomes(["unit-1"], [], []),
             :build_outcomes_do_not_partition_assignment},
            {"overlap", typed_outcomes(["unit-1"], ["unit-1", "unit-2"], []),
             :build_outcome_overlap},
            {"malformed", typed_outcomes(["unit-1", 2], [], ["unit-2"]), :invalid_build_unit_ids},
            {"extra", typed_outcomes(["unit-1", "unit-2", "unit-3"], [], []),
             :build_outcomes_do_not_partition_assignment}
          ] do
        assert {:error, ^reason} =
                 CycleFleet.record_result(assignment, key, %{
                   status: "completed",
                   evidence: "paper://#{key}",
                   evidence_revision: "rev-1",
                   payload: payload
                 })
      end

      assert {:ok, _result} =
               complete_result(
                 assignment,
                 "valid-partition",
                 "completed",
                 typed_outcomes(["unit-1"], ["unit-2"], [])
               )
    end

    test "semantic_receipt-v1 rejects Build07-style structural completion and revalidates history",
         %{scope: scope} do
      units = Enum.map(1..11, &"unit-#{&1}")
      assert {:ok, _wave} = CycleFleet.open_wave(epic_wave_attrs(scope, units))

      assert {:ok, build07} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "build-07", "build", "epic-builder", units)
               )

      assert {:error, :semantic_receipt_task_not_bound} =
               CycleFleet.record_result(build07, "build07-no-proof", %{
                 status: "completed",
                 evidence: "paper://build07/claimed-complete",
                 evidence_revision: "rev-1",
                 payload: typed_outcomes(units, [], [])
               })

      task = ensure_semantic_task!(build07)

      open_task =
        task
        |> Ecto.Changeset.change(
          content: %{
            task.content
            | "lifecycle_status" => "open",
              "acceptance_criteria" => [
                %{
                  "criterion" => "product behavior is actually complete",
                  "met" => false,
                  "evidence" => ""
                }
              ]
          },
          rev: Ecto.UUID.generate()
        )
        |> Repo.update!()

      open_receipts = semantic_receipt_claims(build07, open_task, typed_outcomes(units, [], []))

      assert {:error, :semantic_receipt_task_not_done} =
               CycleFleet.record_result(build07, "build07-open-unmet", %{
                 status: "completed",
                 evidence: "paper://build07/miss-attempt-only",
                 evidence_revision: open_task.rev,
                 payload:
                   units
                   |> typed_outcomes([], [])
                   |> Map.put(:semantic_receipts, open_receipts)
               })

      task =
        open_task
        |> Ecto.Changeset.change(
          content: %{
            open_task.content
            | "lifecycle_status" => "done",
              "acceptance_criteria" => semantic_criteria(build07.assignment_id)
          },
          rev: Ecto.UUID.generate()
        )
        |> Repo.update!()

      assert {:error, :semantic_receipts_required} =
               CycleFleet.record_result(build07, "build07-missing-receipts", %{
                 status: "completed",
                 evidence: "paper://build07/missing-receipts",
                 evidence_revision: "rev-1",
                 payload: typed_outcomes(units, [], [])
               })

      assert {:error, :semantic_receipts_required} =
               Barkpark.EpicFleet.record_result(build07, "build07-direct-ledger-bypass", %{
                 status: "completed",
                 evidence: "paper://build07/direct-ledger-bypass",
                 evidence_revision: "rev-1",
                 payload: typed_outcomes(units, [], [])
               })

      outcomes = typed_outcomes(units, [], [])
      receipts = semantic_receipt_claims(build07, task, outcomes)

      duplicate_receipts = [hd(receipts) | receipts]

      assert {:error, :semantic_receipt_duplicate_unit} =
               CycleFleet.record_result(build07, "build07-duplicate-receipt", %{
                 status: "completed",
                 evidence: "paper://build07/duplicate",
                 evidence_revision: "rev-1",
                 payload: Map.put(outcomes, :semantic_receipts, duplicate_receipts)
               })

      foreign =
        update_in(receipts, [Access.at(0), "task_id"], fn _ -> Ecto.UUID.generate() end)

      assert {:error, :semantic_receipt_foreign_task} =
               CycleFleet.record_result(build07, "build07-foreign-receipt", %{
                 status: "completed",
                 evidence: "paper://build07/foreign",
                 evidence_revision: "rev-1",
                 payload: Map.put(outcomes, :semantic_receipts, foreign)
               })

      stale = update_in(receipts, [Access.at(0), "task_rev"], fn _ -> "stale-rev" end)

      assert {:error, :semantic_receipt_stale_task} =
               CycleFleet.record_result(build07, "build07-stale-receipt", %{
                 status: "completed",
                 evidence: "paper://build07/stale",
                 evidence_revision: "rev-1",
                 payload: Map.put(outcomes, :semantic_receipts, stale)
               })

      malformed_claim = put_in(receipts, [Access.at(0), "claim"], "malformed")

      assert {:error, :semantic_receipt_invalid_claim} =
               CycleFleet.record_result(build07, "build07-malformed-claim", %{
                 status: "completed",
                 evidence: "paper://build07/malformed-claim",
                 evidence_revision: "rev-1",
                 payload: Map.put(outcomes, :semantic_receipts, malformed_claim)
               })

      contradictory =
        update_in(receipts, [Access.at(0), "disposition"], fn _ -> "stalled" end)

      assert {:error, :semantic_receipt_contradiction} =
               CycleFleet.record_result(build07, "build07-contradictory-receipt", %{
                 status: "completed",
                 evidence: "paper://build07/contradiction",
                 evidence_revision: "rev-1",
                 payload: Map.put(outcomes, :semantic_receipts, contradictory)
               })

      attrs = %{
        :status => "completed",
        :evidence => "paper://build07/proved",
        :evidence_revision => "task-rev-1",
        :payload => Map.put(outcomes, :semantic_receipts, receipts),
        "payload" => typed_outcomes([], units, [])
      }

      assert {:ok, first} = CycleFleet.record_result(build07, "build07-proved", attrs)
      assert {:ok, replay} = CycleFleet.record_result(build07, "build07-proved", attrs)
      assert replay.id == first.id
      assert replay.payload_digest == first.payload_digest
      assert first.payload["semantic_receipt_version"] == "semantic_receipt-v1"
      assert length(first.payload["semantic_receipts"]) == 11
      assert String.length(first.payload["semantic_receipt_index_hash"]) == 64
      assert String.length(first.payload["terminal_payload_digest"]) == 64

      assert first.payload["semantic_receipt_index_hash"] ==
               Barkpark.EpicFleet.canonical_digest(%{
                 "version" => "semantic_receipt-index-v1",
                 "terminal_payload_digest" => first.payload["terminal_payload_digest"],
                 "receipt_hashes" =>
                   Enum.map(first.payload["semantic_receipts"], & &1["receipt_hash"])
               })

      assert {:ok, before_stale} = CycleFleet.reconcile(scope)
      assert before_stale.invalid_build_result_assignment_ids == []

      task
      |> Ecto.Changeset.change(rev: Ecto.UUID.generate())
      |> Repo.update!()

      assert Repo.get!(Result, first.id)
      assert {:ok, after_stale} = CycleFleet.reconcile(scope)
      assert after_stale.invalid_build_result_assignment_ids == ["build-07"]
      refute after_stale.exact
    end

    test "semantic_receipt-v1 requires a done Task with met evidence and a retained claim", %{
      scope: scope
    } do
      assert {:ok, _wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      for {id, mutate, reason} <- [
            {"open-task", &Map.put(&1, "lifecycle_status", "open"),
             :semantic_receipt_task_not_done},
            {"unmet-task", &put_in(&1, ["acceptance_criteria", Access.at(0), "met"], false),
             :semantic_receipt_criteria_unmet},
            {"missing-claim", &Map.delete(&1, "claim"), :semantic_receipt_claim_required}
          ] do
        assert {:ok, assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(scope, id, "build", "epic-builder", ["unit-1"])
                 )

        task = ensure_semantic_task!(assignment)
        task |> Ecto.Changeset.change(content: mutate.(task.content)) |> Repo.update!()
        outcomes = typed_outcomes(["unit-1"], [], [])

        assert {:error, ^reason} =
                 CycleFleet.record_result(assignment, "terminal-#{id}", %{
                   status: "completed",
                   evidence: "paper://#{id}",
                   evidence_revision: "rev-1",
                   payload: Map.put(outcomes, :semantic_receipts, [])
                 })
      end
    end

    test "reconciliation quarantines append-only history with a malformed receipt claim", %{
      scope: scope
    } do
      assert {:ok, _wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      assert {:ok, assignment} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "build-malformed-history",
                   "build",
                   "epic-builder",
                   ["unit-1"]
                 )
               )

      task = ensure_semantic_task!(assignment)
      outcomes = typed_outcomes(["unit-1"], [], [])

      malformed =
        assignment
        |> semantic_receipt_claims(task, outcomes)
        |> put_in([Access.at(0), "claim"], "malformed")

      raw_insert_result!(
        assignment,
        "malformed-history",
        Map.put(outcomes, :semantic_receipts, malformed)
      )

      assert Repo.get_by!(Result, assignment_id: assignment.id)
      assert {:ok, summary} = CycleFleet.reconcile(scope)
      assert summary.invalid_build_result_assignment_ids == ["build-malformed-history"]
      refute summary.exact
    end

    test "database rejects a replacement whose predecessor is in another cycle wave", %{
      scope: scope
    } do
      assert {:ok, first_wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      assert {:ok, original} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "build-1", "build", "epic-builder", ["unit-1"])
               )

      assert {:ok, _result} = complete_result(original, "failed-build-1", "failed", %{})

      second_scope = %{scope | wave_id: "wave-2"}
      assert {:ok, second_wave} = CycleFleet.open_wave(epic_wave_attrs(second_scope, ["unit-1"]))
      refute first_wave.id == second_wave.id

      assert_raise Postgrex.Error, ~r/must match cycle wave, scope, phase, and agent type/, fn ->
        raw_insert_assignment!(second_wave, second_scope, %{
          assignment_id: "build-cross-wave-retry",
          phase: "build",
          agent_type: "epic-builder",
          effort: "high",
          snapshot: %{"unit_ids" => ["unit-1"]},
          replaces_assignment_id: original.id
        })
      end
    end

    test "database rejects effort outside the cycle profile", %{scope: scope} do
      assert {:ok, wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      assert_raise Postgrex.Error, ~r/effort is not admitted by the cycle profile/, fn ->
        raw_insert_assignment!(wave, scope, %{
          assignment_id: "survey-wrong-effort",
          phase: "survey",
          agent_type: "epic-surveyor",
          effort: "high",
          snapshot: %{},
          replaces_assignment_id: nil
        })
      end
    end

    test "database rejects a replacement that changes predecessor phase and agent type", %{
      scope: scope
    } do
      assert {:ok, wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1"]))

      assert {:ok, original} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "build-1", "build", "epic-builder", ["unit-1"])
               )

      assert {:ok, _result} = complete_result(original, "failed-build-1", "failed", %{})

      assert_raise Postgrex.Error, ~r/must match cycle wave, scope, phase, and agent type/, fn ->
        raw_insert_assignment!(wave, scope, %{
          assignment_id: "review-cross-phase-retry",
          phase: "review",
          agent_type: "code-reviewer",
          effort: "high",
          snapshot: %{},
          replaces_assignment_id: original.id
        })
      end
    end

    test "database applies sealed batch capacity to replacement snapshots", %{scope: scope} do
      assert {:ok, wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 2))
      complete_experiments(scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(1))

      assert {:ok, original} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "build-1", "build", "legendary-builder", ["unit-1"])
               )

      assert {:ok, _result} = complete_result(original, "failed-build-1", "failed", %{})

      assert %{rows: [[1, 2]]} =
               Repo.query!(
                 """
                 SELECT plan.proven_batch_capacity,
                        jsonb_array_length($1::jsonb->'unit_ids')
                 FROM cycle_build_plans plan
                 WHERE plan.wave_id = $2
                 """,
                 [%{"unit_ids" => ["unit-1", "unit-2"]}, Ecto.UUID.dump!(wave.id)]
               )

      assert_raise Postgrex.Error, ~r/exceeds proven batch capacity/, fn ->
        raw_insert_assignment!(wave, scope, %{
          assignment_id: "build-over-capacity-retry",
          phase: "build",
          agent_type: "legendary-builder",
          effort: "medium",
          snapshot: %{"unit_ids" => ["unit-1", "unit-2"]},
          replaces_assignment_id: original.id
        })
      end
    end

    test "database rejects empty, malformed, duplicate, and foreign Build ownership", %{
      scope: scope
    } do
      assert {:ok, wave} =
               CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1", "unit-2"]))

      for {units, message} <- [
            {[], ~r/non-empty array/},
            {["unit-1", 2], ~r/non-empty strings/},
            {["unit-1", " unit-2"], ~r/unpadded non-empty strings/},
            {["unit-1", "unit-1"], ~r/must be unique/},
            {["unit-unknown"], ~r/belong to cycle inventory/}
          ] do
        assert_raise Postgrex.Error, message, fn ->
          raw_insert_assignment!(wave, scope, %{
            assignment_id: "raw-invalid-#{System.unique_integer([:positive])}",
            phase: "build",
            agent_type: "epic-builder",
            effort: "high",
            snapshot: %{"unit_ids" => units},
            replaces_assignment_id: nil
          })
        end
      end
    end

    test "database rejects malformed and non-partitioning completed Build outcomes", %{
      scope: scope
    } do
      assert {:ok, _wave} =
               CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1", "unit-2"]))

      assert {:ok, assignment} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "db-build-result",
                   "build",
                   "epic-builder",
                   ["unit-1", "unit-2"]
                 )
               )

      assert_raise Postgrex.Error, ~r/typed arrays/, fn ->
        raw_insert_result!(assignment, "db-missing", %{
          "completed_unit_ids" => ["unit-1", "unit-2"]
        })
      end

      assert_raise Postgrex.Error, ~r/must not overlap/, fn ->
        raw_insert_result!(
          assignment,
          "db-overlap",
          stringify_keys(typed_outcomes(["unit-1"], ["unit-1", "unit-2"], []))
        )
      end

      assert_raise Postgrex.Error, ~r/unpadded non-empty strings/, fn ->
        raw_insert_result!(
          assignment,
          "db-padded",
          stringify_keys(typed_outcomes([" unit-1", "unit-2"], [], []))
        )
      end

      assert_raise Postgrex.Error, ~r/exactly partition/, fn ->
        raw_insert_result!(
          assignment,
          "db-partial",
          stringify_keys(typed_outcomes(["unit-1"], [], []))
        )
      end
    end

    test "seal rejects a dangling failed experiment leaf", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 1))

      for {round, round_index} <- Enum.with_index(~w(baseline diverge attack converge pilot)),
          candidate <- 1..3 do
        id = "experiment-#{round_index + 1}-#{candidate}"

        assert {:ok, assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(scope, id, "experiment", "legendary-experimenter", [])
                 )

        status = if id == "experiment-5-3", do: "failed", else: "completed"

        assert {:ok, _result} =
                 complete_result(assignment, "terminal-#{id}", status, %{
                   round: round,
                   candidate: candidate
                 })
      end

      assert {:error, :experiment_assignments_incomplete} =
               CycleFleet.seal_build_plan(scope, build_plan_attrs(1))

      assert {:ok, reduced} = CycleFleet.reduce(scope)
      assert reduced.fleet.experiment.unresolved_failures == 1
    end
  end

  describe "whole-fleet reconciliation" do
    test "database serializes simultaneous genesis promotions with one canonical head" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        workspace = Barkpark.TenancyFixtures.create_workspace!()
        project = Barkpark.TenancyFixtures.create_project!(workspace)

        assert {:ok, _dataset} =
                 Tenancy.create_dataset(project, %{slug: "production", name: "Production"})

        try do
          fixture = raw_promotion_race_fixture!(workspace, project)
          assert {:error, missing_admission} = raw_promotion_without_admission(fixture)
          assert missing_admission =~ "server-issued admission"

          assert {:error, forged_paper} = raw_admission_with_failed_paper!(fixture)
          assert forged_paper =~ "authority"

          assert {:error, forged_b1} = raw_admission_with_forged_b1!(fixture)
          assert forged_b1 =~ "B1 canonical ledger or bytes digest is invalid"

          assert {:error, partial_b1} = raw_admission_with_partial_b1!(fixture)
          assert partial_b1 =~ "B1 attempts do not exactly cover"

          assert {:error, incomplete_live} =
                   raw_promotion_with_incomplete_live_wave(fixture)

          assert incomplete_live =~
                   "Paper and B1 fleet is not backed by complete live Cycle rows"

          assert {:error, invented_correction} =
                   raw_promotion_with_invented_correction_transition(fixture)

          assert invented_correction =~
                   "live Cycle ownership or semantic outcome partition is invalid"

          assert {:error, conflicting_paper} = raw_admission_with_conflicting_paper!(fixture)

          assert conflicting_paper =~
                   "B1 attempts do not exactly cover the authoritative Paper fleet"

          for paper_failure <- [
                raw_admission_with_orphan_paper_revision!(fixture),
                raw_admission_with_unreleased_paper!(fixture),
                raw_admission_with_stale_paper_pointer!(fixture)
              ] do
            assert {:error, stale_paper} = paper_failure
            assert stale_paper =~ "Paper authority is stale or foreign"
          end

          assert_raise Postgrex.Error, ~r/revision history is append-only/, fn ->
            Repo.query!("UPDATE revisions SET action = 'tampered' WHERE id = $1", [
              Ecto.UUID.dump!(fixture.paper.id)
            ])
          end

          assert_raise Postgrex.Error, ~r/revision history is append-only/, fn ->
            Repo.query!("UPDATE revisions SET document_id = NULL WHERE id = $1", [
              Ecto.UUID.dump!(fixture.paper.id)
            ])
          end

          assert_raise Postgrex.Error, ~r/revision history is append-only/, fn ->
            Repo.query!("DELETE FROM revisions WHERE id = $1", [
              Ecto.UUID.dump!(fixture.paper.id)
            ])
          end

          parent = self()

          tasks =
            for key <- ["race-a", "race-b"] do
              Task.async(fn ->
                send(parent, {:promotion_race_ready, self()})

                receive do
                  :promotion_race_go ->
                    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                      raw_genesis_promotion(fixture, key)
                    end)
                end
              end)
            end

          pids =
            Enum.map(tasks, fn _ ->
              assert_receive {:promotion_race_ready, pid}, 1_000
              pid
            end)

          Enum.each(pids, &send(&1, :promotion_race_go))
          results = Task.await_many(tasks, 10_000)

          assert Enum.count(results, &match?({:ok, _}, &1)) == 1
          assert Enum.count(results, &match?({:error, _}, &1)) == 1

          assert %{rows: [[1]]} =
                   Repo.query!(
                     "SELECT count(*) FROM cycle_correction_promotion_events WHERE root_wave_id = $1",
                     [Ecto.UUID.dump!(fixture.root_id)]
                   )
        after
          assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
        end
      end)
    end

    test "correction_of-v1 immutably repairs generic per-unit arithmetic and replays exactly", %{
      scope: scope
    } do
      prior_adapter = Application.get_env(:barkpark, :cycle_release_capture_adapter)
      prior_deployment = Application.get_env(:barkpark, :release_deployment_digest)

      Application.put_env(
        :barkpark,
        :cycle_release_capture_adapter,
        Barkpark.CycleFleetTestReleaseAdapter
      )

      Application.put_env(:barkpark, :release_deployment_digest, String.duplicate("a", 64))

      on_exit(fn ->
        restore_test_env(:cycle_release_capture_adapter, prior_adapter)
        restore_test_env(:release_deployment_digest, prior_deployment)
      end)

      scope = %{scope | wave_id: "wave-3"}
      inventory = Enum.map(1..503, &"unit-#{&1}")
      assert {:ok, prior_wave} = CycleFleet.open_wave(epic_wave_attrs(scope, inventory))

      stable_a_units = Enum.map(1..242, &"unit-#{&1}")
      stable_b_units = Enum.map(243..485, &"unit-#{&1}")

      assert {:ok, stable_a} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "build-stable-a",
                   "build",
                   "epic-builder",
                   stable_a_units
                 )
               )

      assert {:ok, _stable_a_result} =
               complete_result(
                 stable_a,
                 "stable-a-503",
                 "completed",
                 typed_outcomes(
                   Enum.map(1..42, &"unit-#{&1}"),
                   Enum.map(43..242, &"unit-#{&1}"),
                   []
                 )
               )

      assert {:ok, stable_b} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "build-stable-b",
                   "build",
                   "epic-builder",
                   stable_b_units
                 )
               )

      assert {:ok, _stable_b_result} =
               complete_result(
                 stable_b,
                 "stable-b-503",
                 "completed",
                 typed_outcomes(
                   [],
                   Enum.map(243..322, &"unit-#{&1}"),
                   Enum.map(323..485, &"unit-#{&1}")
                 )
               )

      build07_units = Enum.map(486..503, &"unit-#{&1}")

      assert {:ok, build07} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, "build-07", "build", "epic-builder", build07_units)
               )

      assert {:ok, _build07_terminal} =
               complete_result(
                 build07,
                 "build07-structural-lie",
                 "completed",
                 typed_outcomes(
                   Enum.map(486..496, &"unit-#{&1}"),
                   [],
                   Enum.map(497..503, &"unit-#{&1}")
                 )
               )

      semantic_task = ensure_semantic_task!(build07)
      semantic_task |> Ecto.Changeset.change(rev: Ecto.UUID.generate()) |> Repo.update!()

      complete_phase(scope, "survey", "epic-surveyor", 12)
      complete_phase(scope, "verify", "epic-verifier", 6)
      complete_phase(scope, "review", "code-reviewer", 3)

      build07_result = Repo.get_by!(Result, assignment_id: build07.id)
      assert {:ok, before} = CycleFleet.reconcile(scope)
      assert {before.shipped_count, before.stalled_count, before.excluded_count} == {53, 280, 170}
      assert before.invalid_build_result_assignment_ids == ["build-07"]
      assert before.fleet_complete, inspect(before.fleet_counts)
      assert before.experiment.complete?
      refute before.exact

      targets = [
        %{
          "assignment_id" => "build-07",
          "assignment_revision" => build07.id,
          "snapshot_digest" => build07.snapshot_digest,
          "result_revision" => build07_result.id,
          "payload_digest" => build07_result.payload_digest,
          "evidence_revision" => build07_result.evidence_revision,
          "semantic_status" => "invalid",
          "semantic_receipt_index_hash" => build07_result.payload["semantic_receipt_index_hash"]
        }
      ]

      changes =
        Enum.map(486..496, fn index ->
          %{
            "unit_id" => "unit-#{index}",
            "assignment_id" => "build-07",
            "assignment_revision" => build07.id,
            "before" => "shipped",
            "after" => "stalled"
          }
        end)

      correction = %{
        "version" => "correction_of-v1",
        "prior" => %{
          "workspace_id" => prior_wave.workspace_id,
          "project_id" => prior_wave.project_id,
          "epic_id" => prior_wave.epic_id,
          "wave_id" => prior_wave.wave_id,
          "wave_revision" => prior_wave.id,
          "inventory_digest" => prior_wave.inventory_digest,
          "effective_plan_digest" => before.plan_digest,
          "reconciliation_digest" => before.reconciliation_digest
        },
        "ancestry" => [
          %{"wave_id" => prior_wave.wave_id, "wave_revision" => prior_wave.id}
        ],
        "targets" => targets,
        "changes" => changes,
        "inventory_count" => 503,
        "before_counts" => %{"shipped" => 53, "stalled" => 280, "excluded" => 170},
        "delta" => %{"shipped" => -11, "stalled" => 11, "excluded" => 0},
        "after_counts" => %{"shipped" => 42, "stalled" => 291, "excluded" => 170}
      }

      successor_scope = %{scope | wave_id: "wave-3-corrected"}

      attrs =
        Map.merge(successor_scope, %{
          correction_of: correction,
          correction_of_digest: CycleFleet.digest(correction)
        })

      {:ok, open_gate} =
        CycleFleet.admit_open_release_gate(successor_scope, %{
          target_wave_id: successor_scope.wave_id,
          idempotency_key: "open-wave-3-corrected",
          correction_of: correction,
          correction_of_digest: CycleFleet.digest(correction)
        })

      attrs = Map.put(attrs, :release_gate_receipt, open_gate.receipt)

      raw_wrong_delta =
        put_in(correction, ["delta"], %{
          "shipped" => 0,
          "stalled" => 0,
          "excluded" => 0
        })

      assert_raise Postgrex.Error, ~r/correction parent pins are stale or foreign/, fn ->
        raw_insert_correction_wave!(
          prior_wave,
          %{scope | wave_id: "raw-wrong-delta"},
          raw_wrong_delta
        )
      end

      forged_target =
        put_in(
          correction,
          ["targets", Access.at(0), "payload_digest"],
          String.duplicate("0", 64)
        )

      assert_raise Postgrex.Error, ~r/correction parent pins are stale or foreign/, fn ->
        raw_insert_correction_wave!(
          prior_wave,
          %{scope | wave_id: "raw-forged-target"},
          forged_target
        )
      end

      assert {:ok, successor} = CycleFleet.open_wave(attrs)
      assert {:ok, replay} = CycleFleet.open_wave(attrs)
      assert replay.id == successor.id
      assert successor.correction_of_wave_id == prior_wave.id
      assert successor.correction_of == correction
      assert successor.correction_of_digest == CycleFleet.digest(correction)

      assert {:ok, projected} = CycleFleet.reconcile(successor_scope)
      assert {projected.assigned_count, projected.assigned_occurrences} == {503, 503}

      assert {projected.shipped_count, projected.stalled_count, projected.excluded_count} ==
               {42, 291, 170}

      assert projected.unassigned_unit_ids == []
      assert projected.unaccounted_unit_ids == []
      assert String.length(projected.correction_receipt_digest) == 64
      assert projected.correction_of == correction
      assert projected.correction_of_digest == CycleFleet.digest(correction)

      assert projected.correction_ancestry ==
               correction["ancestry"] ++
                 [%{"wave_id" => successor.wave_id, "wave_revision" => successor.id}]

      assert {:ok, successor_projection} = CycleFleet.projection(successor_scope)
      assert successor_projection.fleet == projected.canonical_fleet
      assert successor_projection.cycle_ledger.shipped_count == 42

      assert Enum.all?(successor_projection.own_fleet, fn {_phase, phase} ->
               phase.started == 0
             end)

      assert_raise Postgrex.Error, fn ->
        raw_insert_assignment!(prior_wave, scope, %{
          assignment_id: "late-after-correction",
          phase: "build",
          agent_type: "epic-builder",
          effort: "high",
          snapshot: %{"unit_ids" => ["unit-1"]},
          replaces_assignment_id: nil
        })
      end

      assert_raise Postgrex.Error, fn ->
        raw_insert_assignment!(successor, successor_scope, %{
          assignment_id: "late-on-correction",
          phase: "build",
          agent_type: "epic-builder",
          effort: "high",
          snapshot: %{"unit_ids" => ["unit-1"]},
          replaces_assignment_id: nil
        })
      end

      assert_raise Postgrex.Error, fn ->
        raw_insert_correction_wave!(prior_wave, %{scope | wave_id: "raw-missing-pins"}, %{
          "version" => "correction_of-v1"
        })
      end

      assert_raise Postgrex.Error, fn ->
        raw_insert_correction_wave!(
          prior_wave,
          %{scope | wave_id: "raw-conflicting-profile"},
          correction,
          profile: "legendary"
        )
      end

      forged =
        correction
        |> put_in(["targets", Access.at(0), "assignment_id"], "forged-build")
        |> put_in(["changes", Access.all(), "assignment_id"], "forged-build")

      assert_raise Postgrex.Error, fn ->
        raw_insert_correction_wave!(
          prior_wave,
          %{scope | wave_id: "raw-forged-target"},
          forged
        )
      end

      assert_raise Postgrex.Error, fn ->
        raw_insert_correction_wave!(
          prior_wave,
          %{scope | wave_id: "raw-competing-successor"},
          correction
        )
      end

      assert Repo.get!(Result, build07_result.id).payload == build07_result.payload
      assert {:ok, unchanged_prior} = CycleFleet.reconcile(scope)
      assert unchanged_prior.reconciliation_digest == before.reconciliation_digest

      assert {:ok, chain_before} = CycleFleet.reconcile(successor_scope)

      chain_change = %{
        "unit_id" => "unit-486",
        "assignment_id" => "build-07",
        "assignment_revision" => build07.id,
        "before" => "stalled",
        "after" => "excluded"
      }

      chain_correction = %{
        "version" => "correction_of-v1",
        "prior" => %{
          "workspace_id" => successor.workspace_id,
          "project_id" => successor.project_id,
          "epic_id" => successor.epic_id,
          "wave_id" => successor.wave_id,
          "wave_revision" => successor.id,
          "inventory_digest" => successor.inventory_digest,
          "effective_plan_digest" => chain_before.plan_digest,
          "reconciliation_digest" => chain_before.reconciliation_digest
        },
        "ancestry" => projected.correction_ancestry,
        "targets" => targets,
        "changes" => [chain_change],
        "inventory_count" => 503,
        "before_counts" => %{"shipped" => 42, "stalled" => 291, "excluded" => 170},
        "delta" => %{"shipped" => 0, "stalled" => -1, "excluded" => 1},
        "after_counts" => %{"shipped" => 42, "stalled" => 290, "excluded" => 171}
      }

      wave3_scope = %{scope | wave_id: "wave-3-adversarial"}

      partial_chain =
        put_in(chain_correction, ["ancestry"], [
          %{"wave_id" => successor.wave_id, "wave_revision" => successor.id}
        ])

      assert_raise Postgrex.Error, ~r/correction parent pins are stale or foreign/, fn ->
        raw_insert_correction_wave!(
          successor,
          %{scope | wave_id: "raw-partial-chain"},
          partial_chain
        )
      end

      {:ok, chain_gate} =
        CycleFleet.admit_open_release_gate(wave3_scope, %{
          target_wave_id: wave3_scope.wave_id,
          idempotency_key: "open-wave-3-adversarial",
          correction_of: chain_correction,
          correction_of_digest: CycleFleet.digest(chain_correction)
        })

      assert {:ok, wave3} =
               CycleFleet.open_wave(
                 Map.merge(wave3_scope, %{
                   correction_of: chain_correction,
                   correction_of_digest: CycleFleet.digest(chain_correction),
                   release_gate_receipt: chain_gate.receipt
                 })
               )

      assert wave3.correction_of_wave_id == successor.id
      assert {:ok, wave3_projection} = CycleFleet.reconcile(wave3_scope)

      assert wave3_projection.exact
      assert wave3_projection.fleet_complete
      assert wave3_projection.experiment.complete?

      receipt = wave3_projection.correction_receipt

      dataset =
        Repo.one!(
          from dataset in Barkpark.Tenancy.Dataset,
            where: dataset.project_id == ^scope.project_id and dataset.slug == "production"
        )

      paper =
        released_paper!(scope, dataset, "task06-wave3-paper", %{
          "blocks" => [
            %{
              "type" => "callout",
              "title" => "Agent fleet",
              "cycle_ledger" => stringify_keys(wave3_projection),
              "fleet" => stringify_keys(wave3_projection.canonical_fleet)
            }
          ]
        })

      b1_scope = promotion_b1_scope(wave3, wave3_projection)

      assert {:ok, b1_experiment} =
               Barkpark.EpicFleet.create_benchmark_experiment(%{
                 workspace_id: scope.workspace_id,
                 epic_id: scope.epic_id,
                 wave_id: wave3_scope.wave_id,
                 experiment_id: "task06-wave3-b1",
                 phase: "epic",
                 protocol_version: 1,
                 manifest: %{
                   "cycle_scope_fence" => b1_scope,
                   "fleet_contract" => %{
                     "version" => 1,
                     "paper_fleet_digest" => b1_scope["fleet_digest"]
                   }
                 }
               })

      b1_assignments =
        for phase <- ~w(survey verify experiment build review),
            assignment <-
              wave3_projection.canonical_fleet
              |> Map.get(String.to_existing_atom(phase), %{assignments: []})
              |> Map.get(:assignments, [])
              |> Enum.sort_by(& &1.id) do
          {phase, assignment}
        end

      for {{phase, assignment}, index} <- Enum.with_index(b1_assignments, 1) do
        assert {:ok, _attempt} =
                 Barkpark.EpicFleet.record_benchmark_attempt(b1_experiment, %{
                   attempt_id: "cycle-#{phase}-#{assignment.id}",
                   ordinal: index,
                   treatment: "cyclefleet-reconciliation",
                   status: "completed",
                   costs: %{
                     "wall_seconds" => %{
                       "state" => "unsupported",
                       "reason" => "not recorded"
                     }
                   },
                   provenance: %{
                     "wave_revision" => wave3.id,
                     "scope_receipt_digest" => b1_scope["receipt_digest"]
                   },
                   payload: %{
                     "fleet_assignment" => %{
                       "phase" => phase,
                       "assignment_id" => assignment.id,
                       "agent_type" => assignment.agent_type,
                       "evidence" => assignment.evidence,
                       "model_reasoning_effort" =>
                         if(phase in ["build", "review"], do: "high", else: "medium")
                     }
                   }
                 })
      end

      gate = promotion_gate(wave3, wave3_projection, receipt, paper, b1_experiment)

      correct_b1_scope = promotion_b1_scope(successor, projected)

      correct_b1_assignments =
        for phase <- ~w(survey verify experiment build review),
            assignment <-
              projected.canonical_fleet
              |> Map.get(String.to_existing_atom(phase), %{assignments: []})
              |> Map.get(:assignments, [])
              |> Enum.sort_by(& &1.id) do
          {phase, assignment}
        end

      correct_b1_experiment =
        create_promotion_b1!(
          scope,
          successor,
          correct_b1_scope,
          correct_b1_assignments,
          "task06-wave2-correct-b1"
        )

      correct_release_gate =
        seed_promotable_release_authority!(
          successor_scope,
          prior_wave,
          successor,
          open_gate,
          correct_b1_experiment
        )

      transition = %{
        actor: %{"type" => "agent", "id" => "task06-test"},
        evidence: "paper://task06/promotion",
        evidence_revision: String.duplicate("d", 64)
      }

      assert {:error, :invalid_transition_evidence} =
               CycleFleet.promote_correction(
                 scope,
                 Map.merge(transition, %{
                   idempotency_key: "mutable-evidence-revision",
                   previous_event_id: nil,
                   correction_receipt: receipt,
                   gate_receipt: gate,
                   evidence_revision: "latest"
                 })
               )

      subset_experiment =
        create_promotion_b1!(
          scope,
          wave3,
          b1_scope,
          Enum.drop(b1_assignments, -1),
          "task06-wave3-b1-subset"
        )

      # Promotion now accepts only a consumed Task07 activate receipt. A caller-authored
      # legacy gate is rejected at that stronger outer boundary before legacy validation.
      assert {:error, :invalid_activate_release_gate} =
               CycleFleet.promote_correction(
                 scope,
                 Map.merge(transition, %{
                   idempotency_key: "subset-b1-attempts",
                   previous_event_id: nil,
                   correction_receipt: receipt,
                   gate_receipt:
                     promotion_gate(
                       wave3,
                       wave3_projection,
                       receipt,
                       paper,
                       subset_experiment
                     )
                 })
               )

      foreign_experiment =
        create_promotion_b1!(
          scope,
          wave3,
          b1_scope,
          b1_assignments,
          "task06-wave3-b1-foreign",
          fn attrs, index ->
            if index == 1,
              do: put_in(attrs, [:provenance, :wave_revision], Ecto.UUID.generate()),
              else: attrs
          end
        )

      assert {:error, :invalid_activate_release_gate} =
               CycleFleet.promote_correction(
                 scope,
                 Map.merge(transition, %{
                   idempotency_key: "foreign-b1-provenance",
                   previous_event_id: nil,
                   correction_receipt: receipt,
                   gate_receipt:
                     promotion_gate(
                       wave3,
                       wave3_projection,
                       receipt,
                       paper,
                       foreign_experiment
                     )
                 })
               )

      correct_promote_attrs =
        Map.merge(transition, %{
          idempotency_key: "promote-wave-2-correct",
          previous_event_id: nil,
          correction_receipt: projected.correction_receipt,
          gate_receipt: correct_release_gate.receipt
        })

      assert {:ok, correct_promoted} =
               CycleFleet.promote_correction(scope, correct_promote_attrs)

      wave3_release_gate =
        seed_promotable_release_authority!(
          wave3_scope,
          prior_wave,
          wave3,
          chain_gate,
          b1_experiment
        )

      promote_attrs =
        Map.merge(transition, %{
          idempotency_key: "promote-wave-3",
          previous_event_id: correct_promoted.id,
          correction_receipt: receipt,
          gate_receipt: wave3_release_gate.receipt
        })

      assert {:ok, promoted} = CycleFleet.promote_correction(scope, promote_attrs)
      assert {:ok, replayed} = CycleFleet.promote_correction(wave3_scope, promote_attrs)
      assert replayed.id == promoted.id

      assert {:error, :promotion_conflict} =
               CycleFleet.promote_correction(
                 scope,
                 Map.put(promote_attrs, :evidence_revision, String.duplicate("e", 64))
               )

      assert {:error, :already_current} =
               CycleFleet.promote_correction(
                 scope,
                 %{
                   promote_attrs
                   | idempotency_key: "double-promote",
                     previous_event_id: promoted.id
                 }
               )

      gate_without_semantic = Map.delete(gate, "semantic_digest")

      assert {:error, :invalid_gate_receipt} =
               CycleFleet.promote_correction(
                 scope,
                 %{
                   promote_attrs
                   | idempotency_key: "missing-semantic-gate",
                     previous_event_id: promoted.id,
                     gate_receipt: gate_without_semantic
                 }
               )

      assert {:ok, root_current} = CycleFleet.current_correction(scope)
      assert {:ok, successor_current} = CycleFleet.current_correction(wave3_scope)
      assert root_current.current.wave_revision == wave3.id
      assert successor_current.current == root_current.current

      assert root_current.ancestry_root.wave_id == "wave-3"

      assert Enum.map(root_current.historical_ancestry, & &1.wave_id) == [
               "wave-3-corrected",
               "wave-3-adversarial"
             ]

      assert {:ok, root_reader} = CycleFleet.projection(scope)
      assert {:ok, successor_reader} = CycleFleet.projection(wave3_scope)
      assert root_reader.correction_lifecycle.current.wave_revision == wave3.id
      assert successor_reader.correction_lifecycle == root_reader.correction_lifecycle

      original = root_reader.correction_lifecycle.ancestry_root
      assert original.status == "superseded"
      assert original.wave_id == "wave-3"
      assert original.semantic_snapshot.shipped_count == 53
      assert original.semantic_snapshot.stalled_count == 280
      assert original.semantic_snapshot.excluded_count == 170

      corrected = root_reader.correction_lifecycle.current
      assert corrected.status == "current"
      assert corrected.wave_id == "wave-3-adversarial"

      assert corrected.before_counts == %{
               "shipped" => 42,
               "stalled" => 291,
               "excluded" => 170
             }

      assert corrected.delta == %{"shipped" => 0, "stalled" => -1, "excluded" => 1}

      assert corrected.after_counts == %{
               "shipped" => 42,
               "stalled" => 290,
               "excluded" => 171
             }

      [first_correction, _current_correction] =
        root_reader.correction_lifecycle.historical_ancestry

      assert first_correction.status == "superseded"
      assert first_correction.delta == %{"shipped" => -11, "stalled" => 11, "excluded" => 0}

      assert first_correction.after_counts == %{
               "shipped" => 42,
               "stalled" => 291,
               "excluded" => 170
             }

      reader_authority = root_reader.correction_lifecycle.authority_evidence

      successor_candidate =
        Enum.find(wave3_release_gate.receipt["papers"], &(&1["role"] == "successor"))

      assert reader_authority.paper_revision_id == successor_candidate["candidate_id"]
      assert reader_authority.b1_experiment_id == b1_experiment.id
      assert reader_authority.b1_scope_receipt == b1_scope

      rollback_attrs =
        Map.merge(transition, %{
          idempotency_key: "rollback-wave-3",
          previous_event_id: promoted.id,
          restore_event_id: correct_promoted.id
        })

      assert {:ok, rolled_back} = CycleFleet.rollback_correction(scope, rollback_attrs)

      assert {:error, :stale_promotion_head} =
               CycleFleet.promote_correction(
                 scope,
                 %{
                   promote_attrs
                   | idempotency_key: "stale-promote",
                     previous_event_id: promoted.id
                 }
               )

      promote_again_attrs = %{
        promote_attrs
        | idempotency_key: "promote-wave-3-again",
          previous_event_id: rolled_back.id
      }

      assert {:ok, promoted_again} = CycleFleet.promote_correction(scope, promote_again_attrs)

      assert {:ok, replayed_promote_after_advance} =
               CycleFleet.promote_correction(scope, promote_attrs)

      assert replayed_promote_after_advance.id == promoted.id

      # Exact replay is canonical even after the linked head advances.
      assert {:ok, replayed_rollback} =
               CycleFleet.rollback_correction(wave3_scope, rollback_attrs)

      assert replayed_rollback.id == rolled_back.id

      quarantine_attrs =
        Map.merge(transition, %{
          idempotency_key: "quarantine-wave-3",
          reason: "adversarial verification failed",
          correction_receipt: receipt
        })

      assert {:error, :current_wave_requires_rollback} =
               CycleFleet.quarantine_correction(scope, quarantine_attrs)

      assert {:ok, final_rollback} =
               CycleFleet.rollback_correction(
                 scope,
                 %{
                   rollback_attrs
                   | idempotency_key: "final-rollback",
                     previous_event_id: promoted_again.id
                 }
               )

      assert {:ok, quarantine} = CycleFleet.quarantine_correction(scope, quarantine_attrs)

      assert {:ok, quarantine_replay} =
               CycleFleet.quarantine_correction(wave3_scope, quarantine_attrs)

      assert quarantine_replay.id == quarantine.id

      assert {:ok, rolled_back_reader} = CycleFleet.projection(scope)
      assert rolled_back_reader.correction_lifecycle.current.wave_revision == successor.id
      assert rolled_back_reader.correction_lifecycle.current.status == "current"

      restored_root = rolled_back_reader.correction_lifecycle.ancestry_root
      assert restored_root.status == "superseded"
      assert restored_root.wave_id == "wave-3"
      assert restored_root.semantic_snapshot.shipped_count == 53
      assert restored_root.semantic_snapshot.stalled_count == 280
      assert restored_root.semantic_snapshot.excluded_count == 170

      restored_correct = rolled_back_reader.correction_lifecycle.current
      assert restored_correct.wave_id == "wave-3-corrected"

      assert restored_correct.before_counts == %{
               "shipped" => 53,
               "stalled" => 280,
               "excluded" => 170
             }

      assert restored_correct.delta == %{"shipped" => -11, "stalled" => 11, "excluded" => 0}

      assert restored_correct.after_counts == %{
               "shipped" => 42,
               "stalled" => 291,
               "excluded" => 170
             }

      assert Enum.map(rolled_back_reader.correction_lifecycle.superseded, & &1.wave_revision) == [
               wave3.id
             ]

      [superseded_wave3] = rolled_back_reader.correction_lifecycle.superseded

      assert superseded_wave3.before_counts == %{
               "shipped" => 42,
               "stalled" => 291,
               "excluded" => 170
             }

      assert superseded_wave3.delta == %{"shipped" => 0, "stalled" => -1, "excluded" => 1}

      assert superseded_wave3.after_counts == %{
               "shipped" => 42,
               "stalled" => 290,
               "excluded" => 171
             }

      assert superseded_wave3.semantic_snapshot.shipped_count == 42
      assert superseded_wave3.semantic_snapshot.stalled_count == 290
      assert superseded_wave3.semantic_snapshot.excluded_count == 171

      authority = rolled_back_reader.correction_lifecycle.authority_evidence
      assert authority.target_wave_revision == successor.id
      assert authority.b1_experiment_id == correct_b1_experiment.id
      assert authority.b1_scope_receipt == correct_b1_scope

      correct_successor_candidate =
        Enum.find(correct_release_gate.receipt["papers"], &(&1["role"] == "successor"))

      assert authority.paper_revision_id == correct_successor_candidate["candidate_id"]
      assert authority.fleet_digest == correct_b1_scope["fleet_digest"]

      assert Enum.map(
               rolled_back_reader.correction_lifecycle.historical_ancestry,
               & &1.wave_id
             ) == ["wave-3-corrected", "wave-3-adversarial"]

      assert {:error, :quarantine_conflict} =
               CycleFleet.quarantine_correction(
                 scope,
                 Map.put(quarantine_attrs, :reason, "different evidence")
               )

      assert {:error, :correction_quarantined} =
               CycleFleet.promote_correction(
                 scope,
                 %{
                   promote_attrs
                   | idempotency_key: "blocked-promote",
                     previous_event_id: final_rollback.id
                 }
               )

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE cycle_correction_quarantines SET reason = 'tampered' WHERE id = $1", [
          Ecto.UUID.dump!(quarantine.id)
        ])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM cycle_correction_promotion_events WHERE id = $1", [
          Ecto.UUID.dump!(promoted.id)
        ])
      end

      assert_raise Postgrex.Error, ~r/payload contradicts stored transition/, fn ->
        Repo.query!(
          """
          INSERT INTO cycle_correction_promotion_events
            (id, root_wave_id, target_wave_id, previous_event_id, restore_event_id,
             workspace_id, project_id, epic_id, action, idempotency_key, actor,
             evidence, evidence_revision, gate_receipt, event_payload, event_digest, inserted_at)
          SELECT $1, root_wave_id, target_wave_id, previous_event_id, restore_event_id,
                 workspace_id, project_id, epic_id, action, 'forged-sql-transition', actor,
                 evidence, evidence_revision, gate_receipt, event_payload, event_digest, now()
          FROM cycle_correction_promotion_events WHERE id = $2
          """,
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(promoted.id)]
        )
      end

      assert Enum.map(wave3_projection.correction_ancestry, & &1["wave_id"]) ==
               ["wave-3", "wave-3-corrected", "wave-3-adversarial"]

      repeated_ancestry =
        put_in(
          chain_correction,
          ["ancestry"],
          chain_correction["ancestry"] ++ [hd(chain_correction["ancestry"])]
        )

      assert {:error, :correction_digest_mismatch} =
               CycleFleet.open_wave(
                 Map.merge(%{wave3_scope | wave_id: "repeated-chain"}, %{
                   correction_of: repeated_ancestry,
                   correction_of_digest: CycleFleet.digest(repeated_ancestry)
                 })
               )

      assert {:error, :invalid_open_release_gate} =
               CycleFleet.open_wave(
                 Map.merge(%{successor_scope | wave_id: "competing-successor"}, %{
                   correction_of: correction,
                   correction_of_digest: CycleFleet.digest(correction)
                 })
               )

      assert {:error, :conflicting_correction_contract} =
               CycleFleet.open_wave(
                 Map.put(%{attrs | wave_id: "conflicting-profile"}, :profile, "legendary")
               )

      for {wave_id, key, conflicting} <- [
            {"conflicting-inventory", :inventory, ["foreign-unit"]},
            {"conflicting-experiment", :experiment_contract, %{"unexpected" => true}},
            {"conflicting-scale", :scale_contract, %{"unexpected" => true}}
          ] do
        assert {:error, :conflicting_correction_contract} =
                 CycleFleet.open_wave(
                   attrs
                   |> Map.put(:wave_id, wave_id)
                   |> Map.put(key, conflicting)
                 )
      end

      assert {:error, :same_wave_correction} =
               CycleFleet.open_wave(%{attrs | wave_id: prior_wave.wave_id})

      workspace = Repo.get!(Barkpark.Tenancy.Workspace, scope.workspace_id)

      {:ok, foreign_project} =
        Tenancy.create_project(workspace, %{
          slug: "correction-foreign-#{System.unique_integer([:positive])}",
          name: "Correction foreign"
        })

      assert {:error, :foreign_correction_prior} =
               CycleFleet.open_wave(%{attrs | wave_id: "foreign", project_id: foreign_project.id})

      top_dual = Map.put(attrs, "correction_of", correction)
      assert {:error, :ambiguous_correction_attrs} = CycleFleet.open_wave(top_dual)

      nested_dual =
        update_in(correction, ["changes", Access.at(0)], &Map.put(&1, :before, &1["before"]))

      assert {:error, :ambiguous_correction_attrs} =
               CycleFleet.open_wave(
                 Map.merge(%{successor_scope | wave_id: "nested-dual"}, %{
                   correction_of: nested_dual,
                   correction_of_digest: CycleFleet.digest(nested_dual)
                 })
               )

      missing_ancestry = Map.delete(correction, "ancestry")

      assert {:error, :correction_digest_mismatch} =
               CycleFleet.open_wave(
                 Map.merge(%{successor_scope | wave_id: "missing-ancestry"}, %{
                   correction_of: missing_ancestry,
                   correction_of_digest: CycleFleet.digest(missing_ancestry)
                 })
               )

      assert {:error, :correction_digest_mismatch} =
               CycleFleet.open_wave(%{
                 attrs
                 | wave_id: "wrong-digest",
                   correction_of_digest: String.duplicate("0", 64)
               })

      partial = put_in(correction, ["targets"], [])

      assert {:error, :stale_correction_targets} =
               CycleFleet.open_wave(
                 Map.merge(%{successor_scope | wave_id: "partial"}, %{
                   correction_of: partial,
                   correction_of_digest: CycleFleet.digest(partial)
                 })
               )

      wrong_pin =
        put_in(correction, ["prior", "reconciliation_digest"], String.duplicate("f", 64))

      assert {:error, :stale_correction_prior} =
               CycleFleet.open_wave(
                 Map.merge(%{successor_scope | wave_id: "stale"}, %{
                   correction_of: wrong_pin,
                   correction_of_digest: CycleFleet.digest(wrong_pin)
                 })
               )

      wrong_delta = put_in(correction, ["delta", "shipped"], -10)

      assert {:error, :correction_digest_mismatch} =
               CycleFleet.open_wave(
                 Map.merge(%{successor_scope | wave_id: "wrong-delta"}, %{
                   correction_of: wrong_delta,
                   correction_of_digest: CycleFleet.digest(wrong_delta)
                 })
               )

      survey_assignment = CycleFleet.get_assignment(scope, "survey-1")
      survey_result = Repo.get_by!(Result, assignment_id: survey_assignment.id)

      try do
        Repo.query!("SET LOCAL session_replication_role = replica")

        Repo.query!("UPDATE epic_assignment_results SET status = 'failed' WHERE id = $1", [
          Ecto.UUID.dump!(survey_result.id)
        ])
      after
        Repo.query!("SET LOCAL session_replication_role = origin")
      end

      assert {:error, :correction_not_ready} =
               CycleFleet.promote_correction(
                 scope,
                 %{
                   promote_attrs
                   | idempotency_key: "failed-wave-promote",
                     previous_event_id: final_rollback.id
                 }
               )

      try do
        Repo.query!("SET LOCAL session_replication_role = replica")

        Repo.query!("UPDATE epic_assignment_results SET status = 'completed' WHERE id = $1", [
          Ecto.UUID.dump!(survey_result.id)
        ])
      after
        Repo.query!("SET LOCAL session_replication_role = origin")
      end

      try do
        Repo.query!("SET LOCAL session_replication_role = replica")

        Repo.query!("UPDATE cycle_waves SET correction_of_digest = $1 WHERE id = $2", [
          String.duplicate("0", 64),
          Ecto.UUID.dump!(successor.id)
        ])
      after
        Repo.query!("SET LOCAL session_replication_role = origin")
      end

      assert {:error, :invalid_persisted_correction} = CycleFleet.reconcile(successor_scope)
    end

    test "correction refuses structurally corrupt prior waves", %{scope: scope} do
      assert {:ok, wave} = CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1", "unit-2"]))

      for {id, units} <- [
            {"build-invalid", ["unit-1"]},
            {"build-duplicate", ["unit-1"]},
            {"build-two", ["unit-2"]}
          ] do
        assert {:ok, assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(scope, id, "build", "epic-builder", units)
                 )

        assert {:ok, _result} =
                 complete_result(
                   assignment,
                   "terminal-#{id}",
                   "completed",
                   typed_outcomes(units, [], [])
                 )

        if id == "build-invalid" do
          task = ensure_semantic_task!(assignment)
          task |> Ecto.Changeset.change(rev: Ecto.UUID.generate()) |> Repo.update!()
        end
      end

      complete_phase(scope, "survey", "epic-surveyor", 12)
      complete_phase(scope, "verify", "epic-verifier", 6)
      complete_phase(scope, "review", "code-reviewer", 3)
      assert {:ok, summary} = CycleFleet.reconcile(scope)
      assert summary.duplicate_assignment_unit_ids == ["unit-1"]
      assert summary.invalid_build_result_assignment_ids == ["build-invalid"]

      submitted = %{
        "version" => "correction_of-v1",
        "prior" => %{
          "workspace_id" => wave.workspace_id,
          "project_id" => wave.project_id,
          "epic_id" => wave.epic_id,
          "wave_id" => wave.wave_id,
          "wave_revision" => wave.id,
          "inventory_digest" => wave.inventory_digest,
          "effective_plan_digest" => summary.plan_digest,
          "reconciliation_digest" => summary.reconciliation_digest
        }
      }

      assert {:error, :correction_prior_not_repairable} =
               CycleFleet.open_wave(
                 Map.merge(%{scope | wave_id: "structural-successor"}, %{
                   correction_of: submitted,
                   correction_of_digest: CycleFleet.digest(submitted)
                 })
               )
    end

    test "numeric experiment round keys reconcile and unlock the seal", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 15))

      for {round_key, round} <-
            Enum.with_index(~w(baseline diverge attack converge pilot), 1),
          candidate <- 1..3 do
        id = "numeric-key-#{round}-#{candidate}"

        assert {:ok, assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(scope, id, "experiment", "legendary-experimenter", [])
                 )

        assert {:ok, _result} =
                 complete_result(assignment, "terminal-#{id}", "completed", %{
                   round: round,
                   round_key: round_key,
                   candidate: candidate
                 })
      end

      assert {:ok, summary} = CycleFleet.reconcile(scope)

      assert summary.experiment.round_counts == %{
               "baseline" => 3,
               "diverge" => 3,
               "attack" => 3,
               "converge" => 3,
               "pilot" => 3
             }

      assert summary.experiment.missing_rounds == []
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(5))
    end

    test "numeric experiment rounds fall back to matching canonical round names", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 15))

      for candidate <- 1..3 do
        id = "numeric-baseline-#{candidate}"

        assert {:ok, assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(scope, id, "experiment", "legendary-experimenter", [])
                 )

        assert {:ok, _result} =
                 complete_result(assignment, "terminal-#{id}", "completed", %{
                   round: 1,
                   round_name: "baseline",
                   candidate: candidate
                 })
      end

      for candidate <- 1..3 do
        id = "canonical-diverge-#{candidate}"

        assert {:ok, assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(scope, id, "experiment", "legendary-experimenter", [])
                 )

        assert {:ok, _result} =
                 complete_result(assignment, "terminal-#{id}", "completed", %{
                   round: "diverge",
                   candidate: candidate
                 })
      end

      assert {:ok, summary} = CycleFleet.reconcile(scope)
      assert summary.experiment.round_counts["baseline"] == 3
      assert summary.experiment.round_counts["diverge"] == 3
      assert summary.experiment.missing_rounds == ~w(attack converge pilot)
    end

    test "numeric experiment round keys reject mismatched canonical names", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 15))

      for {round_key, round} <-
            Enum.with_index(~w(baseline diverge attack converge pilot), 1),
          candidate <- 1..3 do
        id = "mismatched-key-#{round}-#{candidate}"
        submitted_key = if round == 1, do: "diverge", else: round_key

        assert {:ok, assignment} =
                 CycleFleet.create_assignment(
                   assignment_attrs(scope, id, "experiment", "legendary-experimenter", [])
                 )

        assert {:ok, _result} =
                 complete_result(assignment, "terminal-#{id}", "completed", %{
                   round: round,
                   round_key: submitted_key,
                   candidate: candidate
                 })
      end

      assert {:ok, summary} = CycleFleet.reconcile(scope)
      assert summary.experiment.round_counts["baseline"] == 0
      assert summary.experiment.round_counts["diverge"] == 3
      assert summary.experiment.missing_rounds == ["baseline"]

      assert {:error, :experiment_assignments_incomplete} =
               CycleFleet.seal_build_plan(scope, build_plan_attrs(5))
    end

    test "Legendary becomes exact only after every planned phase is complete", %{scope: scope} do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 30))
      complete_experiments(scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(10))

      complete_builders(scope, 30)
      assert {:ok, before_fleet} = CycleFleet.reconcile(scope)
      refute before_fleet.exact
      refute before_fleet.fleet_complete

      complete_phase(scope, "survey", "epic-surveyor", 60)
      complete_phase(scope, "verify", "epic-verifier", 30)
      complete_phase(scope, "review", "code-reviewer", 15)

      assert {:ok, summary} = CycleFleet.reconcile(scope)
      assert summary.inventory_count == 30
      assert summary.assigned_count == 30
      assert summary.assigned_occurrences == 30
      assert summary.shipped_count == 28
      assert summary.stalled_count == 1
      assert summary.excluded_count == 1
      assert summary.experiment.complete?
      assert summary.experiment.round_counts["pilot"] == 3
      assert summary.fleet_complete

      assert summary.fleet_counts == %{
               planned: 135,
               started: 135,
               completed: 135,
               failed: 0,
               missing: 0,
               invalid_assignments: 0,
               invalid_results: 0
             }

      assert summary.exact
      assert String.length(summary.reconciliation_digest) == 64
    end

    test "invalid ownership and outcome partitions are rejected before reconciliation", %{
      scope: scope
    } do
      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 15))
      complete_experiments(scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(2))

      assert {:ok, assignment} =
               CycleFleet.create_assignment(
                 assignment_attrs(
                   scope,
                   "build-1",
                   "build",
                   "legendary-builder",
                   ["unit-1", "unit-2"]
                 )
               )

      assert {:error, :build_outcome_overlap} =
               complete_result(assignment, "overlap", "completed", %{
                 completed_unit_ids: ["unit-1", "unit-2"],
                 stalled_unit_ids: ["unit-2"]
               })

      assert {:error, :build_outcomes_do_not_partition_assignment} =
               complete_result(assignment, "extra", "completed", %{
                 completed_unit_ids: ["unit-1", "unit-unknown"]
               })
    end

    test "Epic reaches exact without a build-plan seal", %{scope: scope} do
      assert {:ok, _wave} =
               CycleFleet.open_wave(epic_wave_attrs(scope, ["unit-1", "unit-2", "unit-3"]))

      complete_phase(scope, "survey", "epic-surveyor", 12)
      complete_phase(scope, "verify", "epic-verifier", 6)
      complete_phase(scope, "review", "code-reviewer", 3)

      for index <- 1..3 do
        create_completed_builder(
          scope,
          "build-#{index}",
          ["unit-#{index}"],
          %{completed_unit_ids: ["unit-#{index}"]},
          "epic-builder"
        )
      end

      assert {:ok, summary} = CycleFleet.reconcile(scope)
      assert summary.fleet_complete
      assert summary.capacity.sealed == false
      assert summary.exact
    end
  end

  describe "authority-lock concurrency (mutation-proof)" do
    # Charter D115 / felix-w18 — bind_assignment_task/2 acquires FOR SHARE on the task's
    # authority join (assignment -> wave -> task document -> dataset) BEFORE inserting the
    # AssignmentTask row. The dataset row is the ONLY mutation-sensitive lock target:
    # the assignment row is FK-masked (bind's insert_all FOR-KEY-SHAREs it, so 55P03 fires
    # even with the SELECT lock removed) and the wave row is reached by RI machinery too —
    # both are false-green. Locking the dataset row proves the SELECT's own FOR SHARE:
    # with the lock present a concurrent FOR UPDATE holder forces 55P03; delete the
    # `lock: "FOR SHARE"` clause from cycle_fleet.ex and this same test returns {:ok}.
    #
    # Runs unboxed (two real Postgres connections that actually block each other); the
    # sandbox's single shared transaction cannot observe cross-connection lock ordering.
    # Manual teardown via Tenancy.delete_workspace/1 since unboxed writes are not rolled back.
    test "bind_assignment_task FOR SHARE serializes against a concurrent dataset-row lock (55P03)" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        workspace = Barkpark.TenancyFixtures.create_workspace!("cycle-lock-mutation")
        project = Barkpark.TenancyFixtures.create_project!(workspace, "cycle-lock-mutation")

        scope = %{
          workspace_id: workspace.id,
          project_id: project.id,
          epic_id: "cycle-lock-mutation",
          wave_id: "wave-1"
        }

        try do
          assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 1))
          complete_experiments(scope)
          assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(1))
          chain = create_retry_chain(scope, "legendary-builder")
          assignment = hd(chain)

          {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")

          task =
            %Document{}
            |> Document.changeset(%{
              doc_id: "drafts.cycle-lock-mutation-task",
              type: "task",
              dataset: "production",
              title: "Cycle lock mutation task",
              status: "draft",
              content: %{
                "kind" => "task",
                "acceptance_criteria" => [
                  %{
                    "criterion" => "the fixture states its bar",
                    "met" => true,
                    "evidence" => "fixture"
                  }
                ],
                "lifecycle_status" => "open"
              },
              rev: Ecto.UUID.generate(),
              workspace_id: workspace.id,
              project_id: project.id,
              dataset_id: dataset.id
            })
            |> Repo.insert!()

          parent = self()

          # Connection A: a real second connection holds FOR UPDATE on the task's dataset
          # row and rendezvous-signals the parent BEFORE releasing (holder-first).
          holder =
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                Repo.transaction(fn ->
                  Repo.query!("SELECT id FROM datasets WHERE id = $1 FOR UPDATE", [
                    Ecto.UUID.dump!(dataset.id)
                  ])

                  send(parent, :dataset_row_locked)

                  receive do
                    :release -> :ok
                  after
                    10_000 -> :timeout
                  end
                end)
              end)
            end)

          assert_receive :dataset_row_locked, 5_000

          # Connection B: the test process (inside unboxed_run) drives the REAL
          # bind_assignment_task/2 under a SESSION-level lock_timeout. SET (not SET LOCAL,
          # which is a no-op outside bind's own txn) so the guard survives into bind's
          # transaction; RESET to 0 in the after-block — the GUC persists on the pooled
          # connection and would poison later tests.
          try do
            Repo.query!("SET lock_timeout = '750ms'")

            error =
              assert_raise Postgrex.Error, fn ->
                CycleFleet.bind_assignment_task(assignment, task.id)
              end

            assert error.postgres.code == :lock_not_available
            assert error.postgres.pg_code == "55P03"
          after
            Repo.query!("SET lock_timeout = 0")
            send(holder.pid, :release)
            Task.await(holder, 10_000)
          end
        after
          assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
        end
      end)
    end

    # Charter D115 / felix-w19 — prepare_runtime_attempt/3 acquires FOR UPDATE on the
    # assignment's authority join (assignment -> wave -> binding -> task document ->
    # dataset) BEFORE freezing the RuntimeAttempt row. The dataset row is the
    # mutation-sensitive lock target: the assignment row is FK-masked (the attempt's
    # insert_all FOR-KEY-SHAREs it via assignment_id, so 55P03 fires even with the
    # SELECT lock removed) and the task document row is independently FOR-SHAREd by
    # Tasks.ClaimFence.verify inside the same transaction — both are false-green.
    # Spike-proven 2026-08-17: lock present -> 55P03 at the authority SELECT; delete
    # the `lock: "FOR UPDATE"` clause from runtime_attempt_authority/1 and this same
    # drive returns {:ok, %RuntimeAttempt{}}.
    #
    # Runs unboxed (two real Postgres connections that actually block each other);
    # manual teardown via Tenancy.delete_workspace/1 since unboxed writes are not
    # rolled back. The 55P03 rollback leaves no attempt/session rows behind.
    test "prepare_runtime_attempt FOR UPDATE serializes against a concurrent dataset-row lock (55P03)" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        suffix = System.unique_integer([:positive])
        workspace = Barkpark.TenancyFixtures.create_workspace!("attempt-lock-mutation-#{suffix}")

        project =
          Barkpark.TenancyFixtures.create_project!(workspace, "attempt-lock-mutation-#{suffix}")

        try do
          scope = [workspace_id: workspace.id, project_id: project.id]
          {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")

          for schema_def <- Barkpark.Tasks.schema_definitions("production") do
            attrs =
              schema_def
              |> Map.from_struct()
              |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
              |> Map.new(fn {key, value} -> {to_string(key), value} end)

            {:ok, _} = Barkpark.Content.upsert_schema(attrs, "production", scope)
          end

          {:ok, task} =
            Barkpark.Content.create_document(
              "task",
              %{
                "doc_id" => "attempt-lock-task-#{suffix}",
                "title" => "Attempt lock mutation task",
                "content" => %{
                  "kind" => "task",
                  "acceptance_criteria" => [
                    %{
                      "criterion" => "the fixture states its bar",
                      "met" => true,
                      "evidence" => "fixture"
                    }
                  ],
                  "lifecycle_status" => "open"
                }
              },
              "production",
              scope
            )

          {:ok, claimed} =
            Barkpark.Tasks.claim_by_id(task.doc_id, "attempt-lock-worker", scope)

          cycle_scope = %{
            workspace_id: workspace.id,
            project_id: project.id,
            epic_id: "attempt-lock-epic-#{suffix}",
            wave_id: "wave-1"
          }

          {:ok, _wave} =
            CycleFleet.open_wave(
              Map.merge(cycle_scope, %{
                profile: "epic",
                inventory: ["attempt-lock-unit"],
                scale_contract: %{}
              })
            )

          {:ok, assignment} =
            CycleFleet.create_assignment(
              Map.merge(cycle_scope, %{
                assignment_id: "attempt-lock-unit",
                phase: "survey",
                agent_type: "epic-surveyor",
                effort: "medium",
                task_id: claimed.id,
                snapshot: %{"purpose" => "runtime attempt authority lock"}
              })
            )

          claim = %{
            task_id: claimed.id,
            worker_id: "attempt-lock-worker",
            epoch: get_in(claimed.content, ["claim", "epoch"]),
            work_digest: get_in(claimed.content, ["claim", "work_digest"])
          }

          parent = self()

          # Connection A: a real second connection holds FOR UPDATE on the task's
          # dataset row and rendezvous-signals the parent BEFORE releasing.
          holder =
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                Repo.transaction(fn ->
                  Repo.query!("SELECT id FROM datasets WHERE id = $1 FOR UPDATE", [
                    Ecto.UUID.dump!(dataset.id)
                  ])

                  send(parent, :dataset_row_locked)

                  receive do
                    :release -> :ok
                  after
                    10_000 -> :timeout
                  end
                end)
              end)
            end)

          assert_receive :dataset_row_locked, 5_000

          # Connection B: drive the REAL prepare_runtime_attempt/3 under a
          # SESSION-level lock_timeout (SET LOCAL outside its txn is a no-op);
          # RESET to 0 in the after-block — the GUC persists on the pooled
          # connection and would poison later tests.
          try do
            Repo.query!("SET lock_timeout = '750ms'")

            error =
              assert_raise Postgrex.Error, fn ->
                CycleFleet.prepare_runtime_attempt(assignment, claim)
              end

            assert error.postgres.code == :lock_not_available
            assert error.postgres.pg_code == "55P03"
          after
            Repo.query!("SET lock_timeout = 0")
            send(holder.pid, :release)
            Task.await(holder, 10_000)
          end
        after
          assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
        end
      end)
    end
  end

  defp legendary_wave_attrs(scope, count) do
    count = max(count, 15)

    Map.merge(scope, %{
      profile: "legendary",
      inventory: Enum.map(1..count, &%{unit_id: "unit-#{&1}", class: "reader"}),
      scale_contract: scale_contract(count)
    })
  end

  defp epic_wave_attrs(scope, inventory) do
    Map.merge(scope, %{profile: "epic", inventory: inventory, scale_contract: %{}})
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

  defp typed_outcomes(shipped, stalled, excluded) do
    %{
      completed_unit_ids: shipped,
      stalled_unit_ids: stalled,
      excluded_unit_ids: excluded
    }
  end

  defp promotion_b1_scope(wave, reconciliation) do
    fleet_digest = Barkpark.EpicFleet.canonical_digest(reconciliation.canonical_fleet)

    b1_scope_receipt = %{
      "version" => "b1-scope-fence-v1",
      "workspace_id" => wave.workspace_id,
      "project_id" => wave.project_id,
      "epic_id" => wave.epic_id,
      "wave_id" => wave.wave_id,
      "wave_revision" => wave.id,
      "inventory_digest" => wave.inventory_digest,
      "plan_digest" => reconciliation.plan_digest,
      "reconciliation_digest" => reconciliation.reconciliation_digest,
      "fleet_digest" => fleet_digest
    }

    Map.put(
      b1_scope_receipt,
      "receipt_digest",
      Barkpark.EpicFleet.canonical_digest(b1_scope_receipt)
    )
  end

  defp released_paper!(scope, dataset, doc_id, content) do
    document =
      %Document{}
      |> Document.changeset(%{
        doc_id: doc_id,
        type: "paper",
        dataset: "production",
        dataset_id: dataset.id,
        workspace_id: scope.workspace_id,
        project_id: scope.project_id,
        title: "Cycle promotion authority",
        status: "published",
        content: content,
        rev: Ecto.UUID.generate()
      })
      |> Repo.insert!()

    revision =
      %Revision{}
      |> Revision.changeset(%{
        document_id: document.id,
        doc_id: document.doc_id,
        type: document.type,
        dataset: document.dataset,
        dataset_id: document.dataset_id,
        workspace_id: document.workspace_id,
        project_id: document.project_id,
        title: document.title,
        status: document.status,
        action: "publish",
        content: document.content
      })
      |> Repo.insert!()

    assert Repo.get!(Document, document.id).current_revision_id == revision.id
    assert Repo.get!(Document, document.id).released_revision_id == revision.id
    revision
  end

  defp promotion_gate(wave, reconciliation, receipt, paper, experiment) do
    b1_scope_receipt = promotion_b1_scope(wave, reconciliation)
    {:ok, b1_document} = Barkpark.EpicFleet.export_benchmark(experiment)
    {:ok, b1_bytes} = Barkpark.EpicFleet.export_benchmark_json(experiment)

    unsigned = %{
      "format" => "cycle-promotion-gate-v1",
      "wave_revision" => wave.id,
      "inventory_digest" => wave.inventory_digest,
      "plan_digest" => reconciliation.plan_digest,
      "reconciliation_digest" => reconciliation.reconciliation_digest,
      "correction_receipt_digest" => Barkpark.EpicFleet.canonical_digest(receipt),
      "semantic_digest" => Barkpark.EpicFleet.canonical_digest(receipt["targets"]),
      "b1_scope_receipt_digest" => b1_scope_receipt["receipt_digest"],
      "b1_experiment_id" => experiment.id,
      "b1_ledger_digest" => b1_document["ledger_digest"],
      "b1_bytes_digest" => :sha256 |> :crypto.hash(b1_bytes) |> Base.encode16(case: :lower),
      "paper_document_id" => paper.document_id,
      "paper_revision_id" => paper.id,
      "paper_doc_id" => paper.doc_id,
      "paper_content_digest" => Barkpark.EpicFleet.canonical_digest(paper.content)
    }

    Map.put(unsigned, "receipt_digest", Barkpark.EpicFleet.canonical_digest(unsigned))
  end

  defp create_promotion_b1!(
         scope,
         wave,
         b1_scope,
         assignments,
         experiment_id,
         mutate_attempt \\ fn attrs, _index -> attrs end
       ) do
    {:ok, experiment} =
      Barkpark.EpicFleet.create_benchmark_experiment(%{
        workspace_id: scope.workspace_id,
        epic_id: scope.epic_id,
        wave_id: wave.wave_id,
        experiment_id: experiment_id,
        phase: "epic",
        protocol_version: 1,
        manifest: %{
          "cycle_scope_fence" => b1_scope,
          "fleet_contract" => %{
            "version" => 1,
            "paper_fleet_digest" => b1_scope["fleet_digest"]
          }
        }
      })

    for {{phase, assignment}, index} <- Enum.with_index(assignments, 1) do
      attrs =
        %{
          attempt_id: "cycle-#{phase}-#{assignment.id}",
          ordinal: index,
          treatment: "cyclefleet-reconciliation",
          status: "completed",
          costs: %{
            "wall_seconds" => %{"state" => "unsupported", "reason" => "not recorded"}
          },
          provenance: %{
            wave_revision: wave.id,
            scope_receipt_digest: b1_scope["receipt_digest"]
          },
          payload: %{
            fleet_assignment: %{
              phase: phase,
              assignment_id: assignment.id,
              agent_type: assignment.agent_type,
              evidence: assignment.evidence,
              model_reasoning_effort: if(phase in ["build", "review"], do: "high", else: "medium")
            }
          }
        }
        |> mutate_attempt.(index)

      {:ok, _attempt} = Barkpark.EpicFleet.record_benchmark_attempt(experiment, attrs)
    end

    experiment
  end

  defp raw_promotion_race_fixture!(workspace, project) do
    epic_id = "promotion-race-#{System.unique_integer([:positive])}"

    root_scope = %{
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: epic_id,
      wave_id: "wave-1"
    }

    {:ok, root} = CycleFleet.open_wave(epic_wave_attrs(root_scope, ~w(unit-1 unit-2 unit-3)))

    {:ok, corrected_assignment} =
      CycleFleet.create_assignment(
        assignment_attrs(root_scope, "build-1", "build", "epic-builder", ["unit-1"])
      )

    {:ok, _result} =
      complete_result(corrected_assignment, "race-build-1", "completed", %{
        completed_unit_ids: ["unit-1"]
      })

    stale_task = ensure_semantic_task!(corrected_assignment)
    stale_task |> Ecto.Changeset.change(rev: Ecto.UUID.generate()) |> Repo.update!()

    create_completed_builder(
      root_scope,
      "build-2",
      ["unit-2"],
      %{
        completed_unit_ids: ["unit-2"]
      },
      "epic-builder"
    )

    create_completed_builder(
      root_scope,
      "build-3",
      ["unit-3"],
      %{
        completed_unit_ids: ["unit-3"]
      },
      "epic-builder"
    )

    complete_phase(root_scope, "survey", "epic-surveyor", 12)
    complete_phase(root_scope, "verify", "epic-verifier", 6)
    complete_phase(root_scope, "review", "code-reviewer", 3)

    {:ok, before} = CycleFleet.reconcile(root_scope)
    corrected_result = Repo.get_by!(Result, assignment_id: corrected_assignment.id)

    target_scope = %{root_scope | wave_id: "wave-2"}

    target_pin = %{
      "assignment_id" => corrected_assignment.assignment_id,
      "assignment_revision" => corrected_assignment.id,
      "snapshot_digest" => corrected_assignment.snapshot_digest,
      "result_revision" => corrected_result.id,
      "payload_digest" => corrected_result.payload_digest,
      "evidence_revision" => corrected_result.evidence_revision,
      "semantic_status" => "invalid",
      "semantic_receipt_index_hash" => corrected_result.payload["semantic_receipt_index_hash"]
    }

    correction = %{
      "version" => "correction_of-v1",
      "prior" => %{
        "workspace_id" => root.workspace_id,
        "project_id" => root.project_id,
        "epic_id" => root.epic_id,
        "wave_id" => root.wave_id,
        "wave_revision" => root.id,
        "inventory_digest" => root.inventory_digest,
        "effective_plan_digest" => before.plan_digest,
        "reconciliation_digest" => before.reconciliation_digest
      },
      "ancestry" => [%{"wave_id" => root.wave_id, "wave_revision" => root.id}],
      "targets" => [target_pin],
      "changes" => [
        %{
          "unit_id" => "unit-1",
          "assignment_id" => corrected_assignment.assignment_id,
          "assignment_revision" => corrected_assignment.id,
          "before" => "shipped",
          "after" => "stalled"
        }
      ],
      "inventory_count" => 3,
      "before_counts" => %{"shipped" => 3, "stalled" => 0, "excluded" => 0},
      "delta" => %{"shipped" => -1, "stalled" => 1, "excluded" => 0},
      "after_counts" => %{"shipped" => 2, "stalled" => 1, "excluded" => 0}
    }

    correction_attrs =
      Map.merge(target_scope, %{
        correction_of: correction,
        correction_of_digest: CycleFleet.digest(correction)
      })

    {:ok, open_gate} =
      CycleFleet.admit_open_release_gate(target_scope, %{
        target_wave_id: target_scope.wave_id,
        idempotency_key: "race-open-#{target_scope.wave_id}",
        correction_of: correction,
        correction_of_digest: CycleFleet.digest(correction)
      })

    {:ok, target} =
      CycleFleet.open_wave(Map.put(correction_attrs, :release_gate_receipt, open_gate.receipt))

    {:ok, reconciliation} = CycleFleet.reconcile(target_scope)
    receipt = reconciliation.correction_receipt
    dataset = Repo.one!(from d in Barkpark.Tenancy.Dataset, where: d.project_id == ^project.id)

    paper =
      released_paper!(target_scope, dataset, "race-paper", %{
        "blocks" => [
          %{
            "cycle_ledger" => stringify_keys(reconciliation),
            "fleet" => stringify_keys(reconciliation.canonical_fleet)
          }
        ]
      })

    b1_scope_receipt = promotion_b1_scope(target, reconciliation)

    b1_assignments =
      for phase <- ~w(survey verify experiment build review),
          assignment <-
            reconciliation.canonical_fleet
            |> Map.get(String.to_existing_atom(phase), %{assignments: []})
            |> Map.get(:assignments, [])
            |> Enum.sort_by(& &1.id) do
        {phase, assignment}
      end

    b1_experiment =
      create_promotion_b1!(
        target_scope,
        target,
        b1_scope_receipt,
        b1_assignments,
        "race-b1"
      )

    gate = promotion_gate(target, reconciliation, receipt, paper, b1_experiment)

    release_authority =
      seed_raw_release_authority!(target_scope, root, target, paper, b1_experiment)

    Repo.query!(
      "INSERT INTO cycle_correction_roots (root_wave_id,workspace_id,project_id,epic_id,inserted_at) VALUES ($1,$2,$3,$4,now())",
      [
        Ecto.UUID.dump!(root.id),
        Ecto.UUID.dump!(workspace.id),
        Ecto.UUID.dump!(project.id),
        epic_id
      ]
    )

    Repo.query!(
      """
      INSERT INTO cycle_correction_targets
        (wave_id,root_wave_id,previous_wave_id,workspace_id,project_id,epic_id,
         correction_receipt,correction_receipt_digest,semantic_digest,inserted_at)
      VALUES ($1,$2,$2,$3,$4,$5,$6::jsonb,$7,$8,now())
      """,
      [
        Ecto.UUID.dump!(target.id),
        Ecto.UUID.dump!(root.id),
        Ecto.UUID.dump!(workspace.id),
        Ecto.UUID.dump!(project.id),
        epic_id,
        receipt,
        Barkpark.EpicFleet.canonical_digest(receipt),
        Barkpark.EpicFleet.canonical_digest(receipt["targets"])
      ]
    )

    {:ok, b1_document} = Barkpark.EpicFleet.export_benchmark(b1_experiment)
    {:ok, b1_bytes} = Barkpark.EpicFleet.export_benchmark_json(b1_experiment)

    %{
      root_id: root.id,
      target_id: target.id,
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: epic_id,
      reconciliation_digest: reconciliation.reconciliation_digest,
      fleet_digest: b1_scope_receipt["fleet_digest"],
      b1_scope_receipt: b1_scope_receipt,
      b1_experiment: b1_experiment,
      b1_ledger_digest: b1_document["ledger_digest"],
      b1_bytes_digest: :sha256 |> :crypto.hash(b1_bytes) |> Base.encode16(case: :lower),
      paper: paper,
      gate: gate,
      release_gate_admission_id: release_authority.admission_id,
      release_materialization: release_authority.materialization,
      public_smoke_request: release_authority.public_smoke_request
    }
  end

  defp seed_raw_release_authority!(scope, root, target, successor, b1_experiment) do
    dataset =
      Repo.get!(Barkpark.Tenancy.Dataset, Repo.get!(Document, successor.document_id).dataset_id)

    campaign =
      released_paper!(scope, dataset, "race-campaign", %{
        "blocks" => [%{"type" => "paragraph", "text" => "race campaign"}]
      })

    candidates =
      [{"campaign", campaign}, {"successor", successor}]
      |> Enum.map(fn {role, revision} ->
        document = Repo.get!(Document, revision.document_id)
        source = %{"kind" => "blocks", "blocks" => revision.content["blocks"]}

        attrs = %{
          target_wave_id: target.id,
          role: role,
          document_id: document.id,
          doc_id: document.doc_id,
          base_document_rev: document.rev,
          base_current_revision_id: document.current_revision_id,
          base_released_revision_id: document.released_revision_id,
          title: document.title,
          status: "published",
          content: revision.content,
          content_digest: Barkpark.EpicFleet.canonical_digest(revision.content),
          source_digest: Barkpark.EpicFleet.canonical_digest(source)
        }

        attrs
        |> PaperCandidate.changeset()
        |> Ecto.Changeset.put_change(:id, revision.id)
        |> Repo.insert!()
      end)

    paper_receipts = Enum.map(candidates, &raw_candidate_receipt/1)
    admission_id = Ecto.UUID.generate()

    receipt = %{
      "format" => "cycle-release-gate-receipt-v1",
      "stage" => "activate",
      "admission_id" => admission_id,
      "root_wave_revision" => root.id,
      "target_wave_revision" => target.id,
      "b1_experiment_id" => b1_experiment.id,
      "papers" => paper_receipts
    }

    receipt = Map.put(receipt, "receipt_digest", Barkpark.EpicFleet.canonical_digest(receipt))

    try do
      Repo.query!("SET session_replication_role = replica")

      %{
        stage: "activate",
        root_wave_id: root.id,
        parent_wave_id: root.id,
        target_wave_id: target.id,
        reserved_target_revision: target.id,
        workspace_id: target.workspace_id,
        project_id: target.project_id,
        epic_id: target.epic_id,
        target_wave_key: target.wave_id,
        idempotency_key: "race-activate",
        evidence_bundle: %{"format" => "raw-race-release-authority-v1"},
        receipt: receipt,
        bundle_digest: String.duplicate("c", 64),
        receipt_digest: receipt["receipt_digest"]
      }
      |> ReleaseGate.changeset()
      |> Ecto.Changeset.put_change(:id, admission_id)
      |> Repo.insert!()

      %{
        admission_id: admission_id,
        wave_id: target.id,
        kind: "activate"
      }
      |> Consumption.changeset()
      |> Repo.insert!()
    after
      Repo.query!("SET session_replication_role = origin")
    end

    documents = Enum.map(candidates, &raw_materialization_document/1)

    unsigned_materialization = %{
      "format" => "cycle-release-materialization-v1",
      "release_gate_admission_id" => admission_id,
      "documents" => documents
    }

    materialization =
      Map.put(
        unsigned_materialization,
        "digest",
        Barkpark.EpicFleet.canonical_digest(unsigned_materialization)
      )

    workspace = Repo.get!(Barkpark.Tenancy.Workspace, target.workspace_id)
    project = Repo.get!(Barkpark.Tenancy.Project, target.project_id)
    origin = "https://race.barkpark.test"

    public_smoke_request = %{
      "format" => "cycle-release-public-smoke-request-v1",
      "root_wave_revision" => root.id,
      "target_wave_revision" => target.id,
      "canonical_origin" => origin,
      "workspace_slug" => workspace.slug,
      "project_slug" => project.slug,
      "deployment_digest" => String.duplicate("d", 64),
      "documents" =>
        Enum.map(documents, fn row ->
          %{
            "role" => row["role"],
            "document_id" => row["document_id"],
            "doc_id" => row["doc_id"],
            "title" => row["title"],
            "content_digest" => row["content_digest"],
            "revision_id" => row["after"]["released_revision_id"],
            "url" => "#{origin}/w/#{workspace.slug}/p/#{project.slug}/papers/#{row["doc_id"]}"
          }
        end)
    }

    %{
      admission_id: admission_id,
      materialization: materialization,
      public_smoke_request: public_smoke_request
    }
  end

  defp seed_promotable_release_authority!(scope, root, target, open_gate, b1_experiment) do
    dataset =
      Repo.one!(
        from dataset in Barkpark.Tenancy.Dataset,
          where: dataset.project_id == ^target.project_id and dataset.slug == "production"
      )

    {:ok, lifecycle} = CycleFleet.prospective_correction_lifecycle(scope)
    {:ok, summary} = CycleFleet.reconcile(scope)

    content = %{
      "blocks" => [
        %{
          "type" => "paragraph",
          "text" => "503 total 42 shipped 291 stalled 170 excluded current superseded -11 +11"
        },
        %{
          "type" => "callout",
          "cycle_ledger" => stringify_keys(summary),
          "fleet" => stringify_keys(summary.canonical_fleet),
          "correction_lifecycle" => stringify_keys(lifecycle)
        }
      ]
    }

    candidates =
      Enum.map(~w(campaign successor), fn role ->
        base =
          released_paper!(
            scope,
            dataset,
            "#{target.wave_id}-#{role}-#{System.unique_integer([:positive])}",
            %{"blocks" => [%{"type" => "paragraph", "text" => "base"}]}
          )

        document = Repo.get!(Document, base.document_id)
        source = %{"kind" => "blocks", "blocks" => content["blocks"]}

        %{
          target_wave_id: target.id,
          role: role,
          document_id: document.id,
          doc_id: document.doc_id,
          base_document_rev: document.rev,
          base_current_revision_id: document.current_revision_id,
          base_released_revision_id: document.released_revision_id,
          title: "Cycle #{role}",
          status: "published",
          content: content,
          content_digest: Barkpark.EpicFleet.canonical_digest(content),
          source_digest: Barkpark.EpicFleet.canonical_digest(source)
        }
        |> PaperCandidate.changeset()
        |> Repo.insert!()
      end)

    admission_id = Ecto.UUID.generate()
    paper_receipts = Enum.map(candidates, &raw_candidate_receipt/1)

    evidence = %{"papers" => paper_receipts, "captures" => %{}}

    unsigned_receipt = %{
      "format" => "cycle-release-gate-v1",
      "stage" => "activate",
      "authority" => %{
        "workspace_id" => target.workspace_id,
        "project_id" => target.project_id,
        "epic_id" => target.epic_id,
        "root_wave_revision" => root.id,
        "target_wave_revision" => target.id,
        "open_gate_id" => open_gate.id
      },
      "projection" => %{
        "inventory_count" => 503,
        "assigned_count" => 503,
        "shipped_count" => 42,
        "stalled_count" => 291,
        "excluded_count" => 170,
        "exact" => true,
        "fleet_complete" => true
      },
      "authorities" => %{},
      "b1_experiment_id" => b1_experiment.id,
      "papers" => paper_receipts,
      "captures" => %{},
      "correction_lifecycle_digest" => Barkpark.EpicFleet.canonical_digest(lifecycle),
      "bundle_digest" => Barkpark.EpicFleet.canonical_digest(evidence)
    }

    receipt =
      Map.put(
        unsigned_receipt,
        "receipt_digest",
        Barkpark.EpicFleet.canonical_digest(unsigned_receipt)
      )

    try do
      Repo.query!("SET session_replication_role = replica")

      %{
        stage: "activate",
        root_wave_id: root.id,
        parent_wave_id: open_gate.parent_wave_id,
        target_wave_id: target.id,
        reserved_target_revision: target.id,
        workspace_id: target.workspace_id,
        project_id: target.project_id,
        epic_id: target.epic_id,
        target_wave_key: target.wave_id,
        idempotency_key: "seed-activate-#{target.id}",
        evidence_bundle: evidence,
        receipt: receipt,
        bundle_digest: unsigned_receipt["bundle_digest"],
        receipt_digest: receipt["receipt_digest"]
      }
      |> ReleaseGate.changeset()
      |> Ecto.Changeset.put_change(:id, admission_id)
      |> Repo.insert!()

      %{admission_id: admission_id, wave_id: target.id, kind: "activate"}
      |> Consumption.changeset()
      |> Repo.insert!()
    after
      Repo.query!("SET session_replication_role = origin")
    end

    %{id: admission_id, receipt: receipt}
  end

  defp raw_candidate_receipt(candidate) do
    %{
      "candidate_id" => candidate.id,
      "role" => candidate.role,
      "document_id" => candidate.document_id,
      "doc_id" => candidate.doc_id,
      "title" => candidate.title,
      "base_document_rev" => candidate.base_document_rev,
      "base_current_revision_id" => candidate.base_current_revision_id,
      "base_released_revision_id" => candidate.base_released_revision_id,
      "content_digest" => candidate.content_digest,
      "source_digest" => candidate.source_digest
    }
  end

  defp raw_materialization_document(candidate) do
    %{
      "role" => candidate.role,
      "candidate_id" => candidate.id,
      "document_id" => candidate.document_id,
      "doc_id" => candidate.doc_id,
      "title" => candidate.title,
      "status" => candidate.status,
      "content_digest" => candidate.content_digest,
      "source_digest" => candidate.source_digest,
      "before" => %{
        "rev" => candidate.base_document_rev,
        "current_revision_id" => candidate.base_current_revision_id,
        "released_revision_id" => candidate.base_released_revision_id
      },
      "after" => %{
        "rev" => candidate.id,
        "current_revision_id" => candidate.id,
        "released_revision_id" => candidate.id
      }
    }
  end

  def raw_promotion_race_fixture_legacy!(workspace, project) do
    root_id = Ecto.UUID.generate()
    target_id = Ecto.UUID.generate()
    epic_id = "promotion-race-#{System.unique_integer([:positive])}"
    inventory = [%{"unit_id" => "unit-1"}]
    plan = %{}
    correction = %{"targets" => []}
    correction_digest = CycleFleet.digest(correction)

    Repo.query!(
      """
      INSERT INTO cycle_waves
        (id, workspace_id, project_id, epic_id, wave_id, profile, inventory,
         inventory_digest, plan, plan_digest, experiment_contract, scale_contract, inserted_at)
      VALUES ($1, $2, $3, $4, 'wave-1', 'epic', $5, $6, $7::jsonb, $8,
              '{}'::jsonb, '{}'::jsonb, now())
      """,
      [
        Ecto.UUID.dump!(root_id),
        Ecto.UUID.dump!(workspace.id),
        Ecto.UUID.dump!(project.id),
        epic_id,
        inventory,
        CycleFleet.digest(inventory),
        plan,
        CycleFleet.digest(plan)
      ]
    )

    try do
      Repo.query!("SET session_replication_role = replica")

      Repo.query!(
        """
        INSERT INTO cycle_waves
          (id, workspace_id, project_id, epic_id, wave_id, profile, inventory,
           inventory_digest, plan, plan_digest, experiment_contract, scale_contract,
           correction_of_wave_id, correction_of, correction_of_digest, inserted_at)
        SELECT $1, workspace_id, project_id, epic_id, 'wave-2', profile, inventory,
               inventory_digest, plan, plan_digest, experiment_contract, scale_contract,
               id, $2::jsonb, $3, now()
        FROM cycle_waves WHERE id = $4
        """,
        [
          Ecto.UUID.dump!(target_id),
          correction,
          correction_digest,
          Ecto.UUID.dump!(root_id)
        ]
      )
    after
      Repo.query!("SET session_replication_role = origin")
    end

    receipt = %{
      "version" => "correction_receipt-v1",
      "successor_wave_revision" => target_id,
      "parent_wave_revision" => root_id,
      "correction_of_digest" => correction_digest,
      "targets" => []
    }

    receipt_digest = Barkpark.EpicFleet.canonical_digest(receipt)
    semantic_digest = Barkpark.EpicFleet.canonical_digest([])
    reconciliation_digest = String.duplicate("a", 64)

    fleet = %{
      "survey" => %{
        "assignments" => [
          %{
            "id" => "race-survey",
            "agent_type" => "epic-surveyor",
            "evidence" => "paper://race-survey"
          }
        ]
      },
      "verify" => %{
        "assignments" => [
          %{
            "id" => "race-verify",
            "agent_type" => "epic-verifier",
            "evidence" => "paper://race-verify"
          }
        ]
      }
    }

    fleet_digest = Barkpark.EpicFleet.canonical_digest(fleet)

    b1_scope_receipt = %{
      "version" => "b1-scope-fence-v1",
      "workspace_id" => workspace.id,
      "project_id" => project.id,
      "epic_id" => epic_id,
      "wave_id" => "wave-2",
      "wave_revision" => target_id,
      "inventory_digest" => CycleFleet.digest(inventory),
      "plan_digest" => CycleFleet.digest(plan),
      "reconciliation_digest" => reconciliation_digest,
      "fleet_digest" => fleet_digest
    }

    b1_scope_receipt =
      Map.put(
        b1_scope_receipt,
        "receipt_digest",
        Barkpark.EpicFleet.canonical_digest(b1_scope_receipt)
      )

    dataset = Repo.one!(from d in Barkpark.Tenancy.Dataset, where: d.project_id == ^project.id)

    paper =
      %Revision{}
      |> Revision.changeset(%{
        doc_id: "race-paper",
        type: "paper",
        dataset: dataset.slug,
        dataset_id: dataset.id,
        workspace_id: workspace.id,
        project_id: project.id,
        action: "promotion_gate",
        content: %{
          "blocks" => [
            %{
              "cycle_ledger" => %{
                "scope" => %{
                  "workspace_id" => workspace.id,
                  "project_id" => project.id,
                  "epic_id" => epic_id,
                  "wave_id" => "wave-2"
                },
                "wave_revision" => target_id,
                "inventory_digest" => CycleFleet.digest(inventory),
                "plan_digest" => CycleFleet.digest(plan),
                "reconciliation_digest" => reconciliation_digest,
                "exact" => true,
                "fleet_complete" => true,
                "experiment" => %{"complete?" => true},
                "correction_receipt" => receipt,
                "duplicate_assignment_unit_ids" => [],
                "unknown_assignment_unit_ids" => [],
                "unknown_outcome_unit_ids" => [],
                "outcome_overlap_unit_ids" => [],
                "outcome_ownership_violation_unit_ids" => [],
                "invalid_build_assignment_ids" => [],
                "invalid_build_result_assignment_ids" => [],
                "unassigned_unit_ids" => [],
                "unaccounted_unit_ids" => []
              },
              "fleet" => fleet
            }
          ]
        }
      })
      |> Repo.insert!()

    {:ok, b1_experiment} =
      Barkpark.EpicFleet.create_benchmark_experiment(%{
        workspace_id: workspace.id,
        epic_id: epic_id,
        wave_id: "wave-2",
        experiment_id: "race-b1",
        phase: "epic",
        protocol_version: 1,
        manifest: %{
          "cycle_scope_fence" => b1_scope_receipt,
          "fleet_contract" => %{"version" => 1, "paper_fleet_digest" => fleet_digest}
        }
      })

    for {phase, id, agent_type, ordinal} <- [
          {"survey", "race-survey", "epic-surveyor", 1},
          {"verify", "race-verify", "epic-verifier", 2}
        ] do
      {:ok, _attempt} =
        Barkpark.EpicFleet.record_benchmark_attempt(b1_experiment, %{
          attempt_id: "cycle-#{phase}-#{id}",
          ordinal: ordinal,
          treatment: "cyclefleet-reconciliation",
          status: "completed",
          costs: %{"wall_seconds" => %{"state" => "unsupported", "reason" => "race"}},
          provenance: %{
            "wave_revision" => target_id,
            "scope_receipt_digest" => b1_scope_receipt["receipt_digest"]
          },
          payload: %{
            "fleet_assignment" => %{
              "phase" => phase,
              "assignment_id" => id,
              "agent_type" => agent_type,
              "evidence" => "paper://#{id}",
              "model_reasoning_effort" => "medium"
            }
          }
        })
    end

    {:ok, b1_document} = Barkpark.EpicFleet.export_benchmark(b1_experiment)
    {:ok, b1_bytes} = Barkpark.EpicFleet.export_benchmark_json(b1_experiment)

    Repo.query!(
      """
      INSERT INTO cycle_correction_roots
        (root_wave_id, workspace_id, project_id, epic_id, inserted_at)
      VALUES ($1, $2, $3, $4, now())
      """,
      [
        Ecto.UUID.dump!(root_id),
        Ecto.UUID.dump!(workspace.id),
        Ecto.UUID.dump!(project.id),
        epic_id
      ]
    )

    Repo.query!(
      """
      INSERT INTO cycle_correction_targets
        (wave_id, root_wave_id, previous_wave_id, workspace_id, project_id, epic_id,
         correction_receipt, correction_receipt_digest, semantic_digest, inserted_at)
      VALUES ($1, $2, $2, $3, $4, $5, $6::jsonb, $7, $8, now())
      """,
      [
        Ecto.UUID.dump!(target_id),
        Ecto.UUID.dump!(root_id),
        Ecto.UUID.dump!(workspace.id),
        Ecto.UUID.dump!(project.id),
        epic_id,
        receipt,
        receipt_digest,
        semantic_digest
      ]
    )

    unsigned_gate = %{
      "format" => "cycle-promotion-gate-v1",
      "wave_revision" => target_id,
      "inventory_digest" => CycleFleet.digest(inventory),
      "plan_digest" => CycleFleet.digest(plan),
      "reconciliation_digest" => reconciliation_digest,
      "correction_receipt_digest" => receipt_digest,
      "semantic_digest" => semantic_digest,
      "b1_scope_receipt_digest" => b1_scope_receipt["receipt_digest"],
      "b1_experiment_id" => b1_experiment.id,
      "b1_ledger_digest" => b1_document["ledger_digest"],
      "b1_bytes_digest" => :sha256 |> :crypto.hash(b1_bytes) |> Base.encode16(case: :lower),
      "paper_revision_id" => paper.id,
      "paper_doc_id" => paper.doc_id,
      "paper_content_digest" => Barkpark.EpicFleet.canonical_digest(paper.content)
    }

    %{
      root_id: root_id,
      target_id: target_id,
      workspace_id: workspace.id,
      project_id: project.id,
      epic_id: epic_id,
      reconciliation_digest: reconciliation_digest,
      fleet_digest: fleet_digest,
      b1_scope_receipt: b1_scope_receipt,
      b1_experiment: b1_experiment,
      b1_ledger_digest: b1_document["ledger_digest"],
      b1_bytes_digest: :sha256 |> :crypto.hash(b1_bytes) |> Base.encode16(case: :lower),
      paper: paper,
      gate:
        Map.put(
          unsigned_gate,
          "receipt_digest",
          Barkpark.EpicFleet.canonical_digest(unsigned_gate)
        )
    }
  end

  defp raw_genesis_promotion(fixture, key) do
    event_id = Ecto.UUID.generate()
    admission_id = Ecto.UUID.generate()
    actor = %{"type" => "agent", "id" => key}
    evidence_revision = String.duplicate(if(key == "race-a", do: "a", else: "b"), 64)

    payload = %{
      "action" => "promote",
      "admission_id" => admission_id,
      "root_wave_revision" => fixture.root_id,
      "target_wave_revision" => fixture.target_id,
      "previous_event_id" => nil,
      "restore_event_id" => nil,
      "idempotency_key" => key,
      "actor" => actor,
      "evidence" => "paper://#{key}",
      "evidence_revision" => evidence_revision,
      "gate_receipt" => fixture.gate
    }

    try do
      Repo.query!(
        """
        INSERT INTO cycle_correction_admissions
          (id, root_wave_id, target_wave_id, workspace_id, project_id, epic_id,
           idempotency_key, reconciliation_digest, fleet_digest, b1_scope_receipt,
           b1_scope_receipt_digest, b1_experiment_id, b1_ledger_digest, b1_bytes_digest,
           paper_document_id, paper_revision_id, paper_doc_id, paper_content_digest,
           gate_receipt, gate_receipt_digest, inserted_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11,$12,$13,$14,$15,$16,$17,$18,$19::jsonb,$20,now())
        """,
        [
          Ecto.UUID.dump!(admission_id),
          Ecto.UUID.dump!(fixture.root_id),
          Ecto.UUID.dump!(fixture.target_id),
          Ecto.UUID.dump!(fixture.workspace_id),
          Ecto.UUID.dump!(fixture.project_id),
          fixture.epic_id,
          key,
          fixture.reconciliation_digest,
          fixture.fleet_digest,
          fixture.b1_scope_receipt,
          fixture.b1_scope_receipt["receipt_digest"],
          Ecto.UUID.dump!(fixture.b1_experiment.id),
          fixture.b1_ledger_digest,
          fixture.b1_bytes_digest,
          Ecto.UUID.dump!(fixture.paper.document_id),
          Ecto.UUID.dump!(fixture.paper.id),
          fixture.paper.doc_id,
          Barkpark.EpicFleet.canonical_digest(fixture.paper.content),
          fixture.gate,
          Barkpark.EpicFleet.canonical_digest(fixture.gate)
        ]
      )

      Repo.transaction(fn ->
        result =
          Repo.query!(
            """
            INSERT INTO cycle_correction_promotion_events
              (id, admission_id, release_gate_admission_id, release_materialization,
               root_wave_id, target_wave_id, workspace_id, project_id, epic_id,
               action, idempotency_key, actor, evidence, evidence_revision, gate_receipt,
               event_payload, event_digest, inserted_at)
            VALUES ($1,$2,$3,$4::jsonb,$5,$6,$7,$8,$9,'promote',$10,$11::jsonb,$12,$13,
                    $14::jsonb,$15::jsonb,$16,now())
            RETURNING id
            """,
            [
              Ecto.UUID.dump!(event_id),
              Ecto.UUID.dump!(admission_id),
              Ecto.UUID.dump!(fixture.release_gate_admission_id),
              fixture.release_materialization,
              Ecto.UUID.dump!(fixture.root_id),
              Ecto.UUID.dump!(fixture.target_id),
              Ecto.UUID.dump!(fixture.workspace_id),
              Ecto.UUID.dump!(fixture.project_id),
              fixture.epic_id,
              key,
              actor,
              "paper://#{key}",
              evidence_revision,
              fixture.gate,
              payload,
              Barkpark.EpicFleet.canonical_digest(payload)
            ]
          )

        smoke_request = Map.put(fixture.public_smoke_request, "promotion_event_id", event_id)

        Repo.query!(
          """
          INSERT INTO cycle_release_public_smokes
            (id,promotion_event_id,root_wave_id,target_wave_id,state,request,inserted_at,updated_at)
          VALUES ($1,$2,$3,$4,'pending',$5::jsonb,now(),now())
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(event_id),
            Ecto.UUID.dump!(fixture.root_id),
            Ecto.UUID.dump!(fixture.target_id),
            smoke_request
          ]
        )

        Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")
        result
      end)
    rescue
      error in Postgrex.Error -> {:error, error.postgres.message}
    end
  end

  defp raw_promotion_with_incomplete_live_wave(fixture) do
    result =
      Repo.transaction(fn ->
        Repo.query!(
          "ALTER TABLE epic_assignment_results DISABLE TRIGGER epic_assignment_results_no_update_delete"
        )

        Repo.query!(
          """
          DELETE FROM epic_assignment_results result
          USING epic_assignments assignment
          WHERE result.assignment_id = assignment.id AND assignment.workspace_id = $1 AND
            assignment.epic_id = $2 AND assignment.phase = 'survey' AND
            result.id = (
              SELECT candidate_result.id
              FROM epic_assignment_results candidate_result
              JOIN epic_assignments candidate_assignment
                ON candidate_assignment.id = candidate_result.assignment_id
              WHERE candidate_assignment.workspace_id = $1 AND
                candidate_assignment.epic_id = $2 AND candidate_assignment.phase = 'survey'
              ORDER BY candidate_assignment.assignment_id LIMIT 1
            )
          """,
          [Ecto.UUID.dump!(fixture.workspace_id), fixture.epic_id]
        )

        Repo.query!(
          "ALTER TABLE epic_assignment_results ENABLE TRIGGER epic_assignment_results_no_update_delete"
        )

        Repo.rollback(raw_genesis_promotion(fixture, "incomplete-live"))
      end)

    case result do
      {:error, admission_result} -> admission_result
    end
  end

  defp raw_promotion_with_invented_correction_transition(fixture) do
    result =
      Repo.transaction(fn ->
        Repo.query!("ALTER TABLE cycle_waves DISABLE TRIGGER cycle_waves_no_update_delete")

        Repo.query!(
          """
          UPDATE cycle_waves
          SET correction_of = jsonb_set(correction_of, '{changes,0,before}', '"excluded"')
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(fixture.target_id)]
        )

        Repo.query!("ALTER TABLE cycle_waves ENABLE TRIGGER cycle_waves_no_update_delete")
        Repo.rollback(raw_genesis_promotion(fixture, "invented-correction-transition"))
      end)

    case result do
      {:error, admission_result} -> admission_result
    end
  end

  defp raw_promotion_without_admission(fixture) do
    key = "missing-admission"
    actor = %{"type" => "agent", "id" => key}
    revision = String.duplicate("f", 64)

    payload = %{
      "action" => "promote",
      "admission_id" => nil,
      "root_wave_revision" => fixture.root_id,
      "target_wave_revision" => fixture.target_id,
      "previous_event_id" => nil,
      "restore_event_id" => nil,
      "idempotency_key" => key,
      "actor" => actor,
      "evidence" => "paper://#{key}",
      "evidence_revision" => revision,
      "gate_receipt" => fixture.gate
    }

    try do
      {:ok,
       Repo.query!(
         """
         INSERT INTO cycle_correction_promotion_events
           (id, root_wave_id, target_wave_id, workspace_id, project_id, epic_id,
            action, idempotency_key, actor, evidence, evidence_revision, gate_receipt,
            event_payload, event_digest, inserted_at)
         VALUES ($1,$2,$3,$4,$5,$6,'promote',$7,$8::jsonb,$9,$10,$11::jsonb,$12::jsonb,$13,now())
         """,
         [
           Ecto.UUID.dump!(Ecto.UUID.generate()),
           Ecto.UUID.dump!(fixture.root_id),
           Ecto.UUID.dump!(fixture.target_id),
           Ecto.UUID.dump!(fixture.workspace_id),
           Ecto.UUID.dump!(fixture.project_id),
           fixture.epic_id,
           key,
           actor,
           "paper://#{key}",
           revision,
           fixture.gate,
           payload,
           Barkpark.EpicFleet.canonical_digest(payload)
         ]
       )}
    rescue
      error in Postgrex.Error -> {:error, error.postgres.message}
    end
  end

  defp raw_admission_with_failed_paper!(fixture) do
    [block] = fixture.paper.content["blocks"]
    failed_content = %{"blocks" => [put_in(block, ["cycle_ledger", "exact"], false)]}

    failed_paper =
      %Revision{}
      |> Revision.changeset(%{
        doc_id: "failed-race-paper",
        type: "paper",
        dataset: fixture.paper.dataset,
        dataset_id: fixture.paper.dataset_id,
        workspace_id: fixture.workspace_id,
        project_id: fixture.project_id,
        action: "promotion_gate",
        content: failed_content
      })
      |> Repo.insert!()

    unsigned_gate =
      fixture.gate
      |> Map.drop(["receipt_digest"])
      |> Map.put("paper_revision_id", failed_paper.id)
      |> Map.put("paper_doc_id", failed_paper.doc_id)
      |> Map.put(
        "paper_content_digest",
        Barkpark.EpicFleet.canonical_digest(failed_paper.content)
      )

    gate =
      Map.put(unsigned_gate, "receipt_digest", Barkpark.EpicFleet.canonical_digest(unsigned_gate))

    try do
      {:ok,
       Repo.query!(
         """
         INSERT INTO cycle_correction_admissions
           (id, root_wave_id, target_wave_id, workspace_id, project_id, epic_id,
            idempotency_key, reconciliation_digest, fleet_digest, b1_scope_receipt,
            b1_scope_receipt_digest, b1_experiment_id, b1_ledger_digest, b1_bytes_digest,
            paper_document_id, paper_revision_id, paper_doc_id, paper_content_digest, gate_receipt,
            gate_receipt_digest, inserted_at)
         VALUES ($1,$2,$3,$4,$5,$6,'failed-paper',$7,$8,$9::jsonb,$10,$11,$12,$13,$14,$15,$16,$17,$18::jsonb,$19,now())
         """,
         [
           Ecto.UUID.dump!(Ecto.UUID.generate()),
           Ecto.UUID.dump!(fixture.root_id),
           Ecto.UUID.dump!(fixture.target_id),
           Ecto.UUID.dump!(fixture.workspace_id),
           Ecto.UUID.dump!(fixture.project_id),
           fixture.epic_id,
           fixture.reconciliation_digest,
           fixture.fleet_digest,
           fixture.b1_scope_receipt,
           fixture.b1_scope_receipt["receipt_digest"],
           Ecto.UUID.dump!(fixture.b1_experiment.id),
           fixture.b1_ledger_digest,
           fixture.b1_bytes_digest,
           Ecto.UUID.dump!(fixture.paper.document_id),
           Ecto.UUID.dump!(failed_paper.id),
           failed_paper.doc_id,
           Barkpark.EpicFleet.canonical_digest(failed_paper.content),
           gate,
           Barkpark.EpicFleet.canonical_digest(gate)
         ]
       )}
    rescue
      error in Postgrex.Error -> {:error, error.postgres.message}
    end
  end

  defp raw_admission_with_conflicting_paper!(fixture) do
    [authority] = fixture.paper.content["blocks"]
    dataset = Repo.get!(Barkpark.Tenancy.Dataset, fixture.paper.dataset_id)

    paper =
      released_paper!(
        %{workspace_id: fixture.workspace_id, project_id: fixture.project_id},
        dataset,
        "conflicting-race-paper",
        %{"blocks" => [authority, authority]}
      )

    raw_admission_with_paper!(fixture, paper, "conflicting-paper")
  end

  defp raw_admission_with_orphan_paper_revision!(fixture) do
    paper =
      %Revision{}
      |> Revision.changeset(%{
        doc_id: "orphan-race-paper",
        type: "paper",
        dataset: "production",
        dataset_id: fixture.paper.dataset_id,
        workspace_id: fixture.workspace_id,
        project_id: fixture.project_id,
        title: "Orphan cycle authority",
        status: "published",
        action: "publish",
        content: fixture.paper.content
      })
      |> Repo.insert!()

    raw_admission_with_paper!(fixture, paper, "orphan-paper", fixture.paper.document_id)
  end

  defp raw_admission_with_unreleased_paper!(fixture) do
    document =
      %Document{}
      |> Document.changeset(%{
        doc_id: "unreleased-race-paper",
        type: "paper",
        dataset: "production",
        dataset_id: fixture.paper.dataset_id,
        workspace_id: fixture.workspace_id,
        project_id: fixture.project_id,
        title: "Unreleased cycle authority",
        status: "published",
        content: fixture.paper.content,
        rev: Ecto.UUID.generate()
      })
      |> Repo.insert!()

    paper =
      %Revision{}
      |> Revision.changeset(%{
        document_id: document.id,
        doc_id: document.doc_id,
        type: document.type,
        dataset: document.dataset,
        dataset_id: document.dataset_id,
        workspace_id: document.workspace_id,
        project_id: document.project_id,
        title: document.title,
        status: document.status,
        action: "update",
        content: document.content
      })
      |> Repo.insert!()

    assert Repo.get!(Document, document.id).current_revision_id == paper.id
    assert Repo.get!(Document, document.id).released_revision_id == nil
    raw_admission_with_paper!(fixture, paper, "unreleased-paper")
  end

  defp raw_admission_with_stale_paper_pointer!(fixture) do
    {:error, admission_result} =
      Repo.transaction(fn ->
        document = Repo.get!(Document, fixture.paper.document_id)

        current =
          %Revision{}
          |> Revision.changeset(%{
            document_id: document.id,
            doc_id: document.doc_id,
            type: document.type,
            dataset: document.dataset,
            dataset_id: document.dataset_id,
            workspace_id: document.workspace_id,
            project_id: document.project_id,
            title: document.title,
            status: document.status,
            action: "update",
            content: document.content
          })
          |> Repo.insert!()

        assert Repo.get!(Document, document.id).current_revision_id == current.id
        assert Repo.get!(Document, document.id).released_revision_id == fixture.paper.id
        Repo.rollback(raw_admission_with_paper!(fixture, fixture.paper, "stale-paper"))
      end)

    admission_result
  end

  defp raw_admission_with_paper!(fixture, paper, key, paper_document_id \\ nil) do
    paper_document_id = paper_document_id || paper.document_id

    unsigned_gate =
      fixture.gate
      |> Map.drop(["receipt_digest"])
      |> Map.merge(%{
        "paper_document_id" => paper_document_id,
        "paper_revision_id" => paper.id,
        "paper_doc_id" => paper.doc_id,
        "paper_content_digest" => Barkpark.EpicFleet.canonical_digest(paper.content)
      })

    gate =
      Map.put(unsigned_gate, "receipt_digest", Barkpark.EpicFleet.canonical_digest(unsigned_gate))

    try do
      {:ok,
       Repo.query!(
         """
         INSERT INTO cycle_correction_admissions
           (id, root_wave_id, target_wave_id, workspace_id, project_id, epic_id,
            idempotency_key, reconciliation_digest, fleet_digest, b1_scope_receipt,
            b1_scope_receipt_digest, b1_experiment_id, b1_ledger_digest, b1_bytes_digest,
            paper_document_id, paper_revision_id, paper_doc_id, paper_content_digest, gate_receipt,
            gate_receipt_digest, inserted_at)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11,$12,$13,$14,$15,$16,$17,$18,$19::jsonb,$20,now())
         """,
         [
           Ecto.UUID.dump!(Ecto.UUID.generate()),
           Ecto.UUID.dump!(fixture.root_id),
           Ecto.UUID.dump!(fixture.target_id),
           Ecto.UUID.dump!(fixture.workspace_id),
           Ecto.UUID.dump!(fixture.project_id),
           fixture.epic_id,
           key,
           fixture.reconciliation_digest,
           fixture.fleet_digest,
           fixture.b1_scope_receipt,
           fixture.b1_scope_receipt["receipt_digest"],
           Ecto.UUID.dump!(fixture.b1_experiment.id),
           fixture.b1_ledger_digest,
           fixture.b1_bytes_digest,
           Ecto.UUID.dump!(paper_document_id),
           Ecto.UUID.dump!(paper.id),
           paper.doc_id,
           Barkpark.EpicFleet.canonical_digest(paper.content),
           gate,
           Barkpark.EpicFleet.canonical_digest(gate)
         ]
       )}
    rescue
      error in Postgrex.Error -> {:error, error.postgres.message}
    end
  end

  defp raw_admission_with_forged_b1!(fixture) do
    forged_digest = String.duplicate("0", 64)

    unsigned_gate =
      fixture.gate
      |> Map.drop(["receipt_digest"])
      |> Map.put("b1_ledger_digest", forged_digest)

    gate =
      Map.put(unsigned_gate, "receipt_digest", Barkpark.EpicFleet.canonical_digest(unsigned_gate))

    try do
      {:ok,
       Repo.query!(
         """
         INSERT INTO cycle_correction_admissions
           (id, root_wave_id, target_wave_id, workspace_id, project_id, epic_id,
            idempotency_key, reconciliation_digest, fleet_digest, b1_scope_receipt,
            b1_scope_receipt_digest, b1_experiment_id, b1_ledger_digest, b1_bytes_digest,
            paper_document_id, paper_revision_id, paper_doc_id, paper_content_digest, gate_receipt,
            gate_receipt_digest, inserted_at)
         VALUES ($1,$2,$3,$4,$5,$6,'forged-b1',$7,$8,$9::jsonb,$10,$11,$12,$13,$14,$15,$16,$17,$18::jsonb,$19,now())
         """,
         [
           Ecto.UUID.dump!(Ecto.UUID.generate()),
           Ecto.UUID.dump!(fixture.root_id),
           Ecto.UUID.dump!(fixture.target_id),
           Ecto.UUID.dump!(fixture.workspace_id),
           Ecto.UUID.dump!(fixture.project_id),
           fixture.epic_id,
           fixture.reconciliation_digest,
           fixture.fleet_digest,
           fixture.b1_scope_receipt,
           fixture.b1_scope_receipt["receipt_digest"],
           Ecto.UUID.dump!(fixture.b1_experiment.id),
           forged_digest,
           fixture.b1_bytes_digest,
           Ecto.UUID.dump!(fixture.paper.document_id),
           Ecto.UUID.dump!(fixture.paper.id),
           fixture.paper.doc_id,
           Barkpark.EpicFleet.canonical_digest(fixture.paper.content),
           gate,
           Barkpark.EpicFleet.canonical_digest(gate)
         ]
       )}
    rescue
      error in Postgrex.Error -> {:error, error.postgres.message}
    end
  end

  defp raw_admission_with_partial_b1!(fixture) do
    {:ok, experiment} =
      Barkpark.EpicFleet.create_benchmark_experiment(%{
        workspace_id: fixture.workspace_id,
        epic_id: fixture.epic_id,
        wave_id: "wave-2",
        experiment_id: "race-b1-partial",
        phase: "epic",
        protocol_version: 1,
        manifest: %{
          "cycle_scope_fence" => fixture.b1_scope_receipt,
          "fleet_contract" => %{
            "version" => 1,
            "paper_fleet_digest" => fixture.fleet_digest
          }
        }
      })

    {:ok, _attempt} =
      Barkpark.EpicFleet.record_benchmark_attempt(experiment, %{
        attempt_id: "cycle-survey-race-survey",
        ordinal: 1,
        treatment: "cyclefleet-reconciliation",
        status: "completed",
        costs: %{"wall_seconds" => %{"state" => "unsupported", "reason" => "partial"}},
        provenance: %{
          "wave_revision" => fixture.target_id,
          "scope_receipt_digest" => fixture.b1_scope_receipt["receipt_digest"]
        },
        payload: %{
          "fleet_assignment" => %{
            "phase" => "survey",
            "assignment_id" => "race-survey",
            "agent_type" => "epic-surveyor",
            "evidence" => "paper://race-survey",
            "model_reasoning_effort" => "medium"
          }
        }
      })

    {:ok, document} = Barkpark.EpicFleet.export_benchmark(experiment)
    {:ok, bytes} = Barkpark.EpicFleet.export_benchmark_json(experiment)
    bytes_digest = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    unsigned_gate =
      fixture.gate
      |> Map.drop(["receipt_digest"])
      |> Map.merge(%{
        "b1_experiment_id" => experiment.id,
        "b1_ledger_digest" => document["ledger_digest"],
        "b1_bytes_digest" => bytes_digest
      })

    gate =
      Map.put(unsigned_gate, "receipt_digest", Barkpark.EpicFleet.canonical_digest(unsigned_gate))

    try do
      {:ok,
       Repo.query!(
         """
         INSERT INTO cycle_correction_admissions
           (id, root_wave_id, target_wave_id, workspace_id, project_id, epic_id,
            idempotency_key, reconciliation_digest, fleet_digest, b1_scope_receipt,
            b1_scope_receipt_digest, b1_experiment_id, b1_ledger_digest, b1_bytes_digest,
            paper_document_id, paper_revision_id, paper_doc_id, paper_content_digest, gate_receipt,
            gate_receipt_digest, inserted_at)
         VALUES ($1,$2,$3,$4,$5,$6,'partial-b1',$7,$8,$9::jsonb,$10,$11,$12,$13,$14,$15,$16,$17,$18::jsonb,$19,now())
         """,
         [
           Ecto.UUID.dump!(Ecto.UUID.generate()),
           Ecto.UUID.dump!(fixture.root_id),
           Ecto.UUID.dump!(fixture.target_id),
           Ecto.UUID.dump!(fixture.workspace_id),
           Ecto.UUID.dump!(fixture.project_id),
           fixture.epic_id,
           fixture.reconciliation_digest,
           fixture.fleet_digest,
           fixture.b1_scope_receipt,
           fixture.b1_scope_receipt["receipt_digest"],
           Ecto.UUID.dump!(experiment.id),
           document["ledger_digest"],
           bytes_digest,
           Ecto.UUID.dump!(fixture.paper.document_id),
           Ecto.UUID.dump!(fixture.paper.id),
           fixture.paper.doc_id,
           Barkpark.EpicFleet.canonical_digest(fixture.paper.content),
           gate,
           Barkpark.EpicFleet.canonical_digest(gate)
         ]
       )}
    rescue
      error in Postgrex.Error -> {:error, error.postgres.message}
    end
  end

  defp build_plan_attrs(capacity) do
    %{
      proven_batch_capacity: capacity,
      chosen_format: "golden-v1",
      pilot_evidence: "paper://pilot/golden-v1",
      pilot_evidence_revision: "pilot-rev-1",
      failure_rate: 0.0,
      failure_threshold: 0.05,
      golden_fixtures: ["paper://fixtures/good", "paper://fixtures/bad"]
    }
  end

  defp assignment_attrs(scope, id, phase, agent_type, units) do
    Map.merge(scope, %{
      assignment_id: id,
      phase: phase,
      agent_type: agent_type,
      effort: effort_for(phase, agent_type),
      snapshot: %{unit_ids: units}
    })
  end

  defp effort_for(phase, _agent_type) when phase in ["survey", "verify", "experiment"],
    do: "medium"

  defp effort_for("build", "legendary-builder"), do: "medium"
  defp effort_for(_phase, _agent_type), do: "high"

  defp raw_insert_assignment!(wave, scope, attrs) do
    snapshot = attrs.snapshot

    Repo.query!(
      """
      INSERT INTO epic_assignments
        (id, workspace_id, epic_id, wave_id, assignment_id, phase, agent_type,
         effort, snapshot, snapshot_digest, cycle_wave_id, replaces_assignment_id, inserted_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11, $12, now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(scope.workspace_id),
        scope.epic_id,
        scope.wave_id,
        attrs.assignment_id,
        attrs.phase,
        attrs.agent_type,
        attrs.effort,
        snapshot,
        CycleFleet.digest(snapshot),
        Ecto.UUID.dump!(wave.id),
        attrs.replaces_assignment_id && Ecto.UUID.dump!(attrs.replaces_assignment_id)
      ]
    )
  end

  defp raw_insert_wave!(scope, profile, inventory) do
    plan = %{}

    Repo.query!(
      """
      INSERT INTO cycle_waves
        (id, workspace_id, project_id, epic_id, wave_id, profile, inventory,
         inventory_digest, plan, plan_digest, experiment_contract, scale_contract, inserted_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, '{}'::jsonb, '{}'::jsonb, now())
      RETURNING id
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(scope.workspace_id),
        scope.project_id && Ecto.UUID.dump!(scope.project_id),
        scope.epic_id,
        scope.wave_id,
        profile,
        inventory,
        CycleFleet.digest(inventory),
        plan,
        CycleFleet.digest(plan)
      ]
    )
  end

  defp raw_insert_correction_wave!(parent, scope, correction, opts \\ []) do
    profile = Keyword.get(opts, :profile, parent.profile)
    plan = parent.plan

    Repo.query!(
      """
      INSERT INTO cycle_waves
        (id, workspace_id, project_id, epic_id, wave_id, profile, inventory,
         inventory_digest, plan, plan_digest, experiment_contract, scale_contract,
         correction_of_wave_id, correction_of, correction_of_digest, inserted_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11::jsonb, $12::jsonb,
         $13, $14::jsonb, $15, now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(scope.workspace_id),
        scope.project_id && Ecto.UUID.dump!(scope.project_id),
        scope.epic_id,
        scope.wave_id,
        profile,
        parent.inventory,
        parent.inventory_digest,
        plan,
        parent.plan_digest,
        parent.experiment_contract,
        parent.scale_contract,
        Ecto.UUID.dump!(parent.id),
        correction,
        CycleFleet.digest(correction)
      ]
    )
  end

  defp raw_insert_result!(assignment, idempotency_key, payload) do
    Repo.query!(
      """
      INSERT INTO epic_assignment_results
        (id, assignment_id, idempotency_key, status, evidence, evidence_revision,
         evidence_digest, payload, payload_digest, inserted_at)
      VALUES ($1, $2, $3, 'completed', $4, 'rev-1', $5, $6::jsonb, $7, now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(assignment.id),
        idempotency_key,
        "paper://#{idempotency_key}",
        CycleFleet.digest(%{evidence: "paper://#{idempotency_key}", evidence_revision: "rev-1"}),
        payload,
        CycleFleet.digest(payload)
      ]
    )
  end

  defp complete_experiments(scope) do
    for {round, round_index} <- Enum.with_index(~w(baseline diverge attack converge pilot)),
        candidate <- 1..3 do
      id = "experiment-#{round_index + 1}-#{candidate}"

      assert {:ok, assignment} =
               CycleFleet.create_assignment(
                 assignment_attrs(scope, id, "experiment", "legendary-experimenter", [])
               )

      assert {:ok, _result} =
               complete_result(assignment, "terminal-#{id}", "completed", %{
                 round: round,
                 candidate: candidate
               })
    end
  end

  defp complete_phase(scope, phase, agent_type, count) do
    for index <- 1..count do
      id = "#{phase}-#{index}"

      assert {:ok, assignment} =
               CycleFleet.create_assignment(assignment_attrs(scope, id, phase, agent_type, []))

      assert {:ok, _result} = complete_result(assignment, "terminal-#{id}", "completed", %{})
    end
  end

  defp create_retry_chain(scope, agent_type) do
    original_attrs = assignment_attrs(scope, "build-1", "build", agent_type, ["unit-1"])
    assert {:ok, original} = CycleFleet.create_assignment(original_attrs)
    assert {:ok, _result} = complete_result(original, "terminal-build-1", "failed", %{})

    retry_attrs =
      scope
      |> assignment_attrs("build-1-retry", "build", agent_type, ["unit-1"])
      |> Map.put(:replaces_assignment_id, original.assignment_id)

    assert {:ok, retry} = CycleFleet.create_assignment(retry_attrs)
    assert {:ok, _result} = complete_result(retry, "terminal-build-1-retry", "failed", %{})

    second_retry_attrs =
      scope
      |> assignment_attrs("build-1-retry-2", "build", agent_type, ["unit-1"])
      |> Map.put(:replaces_assignment_id, retry.assignment_id)

    assert {:ok, second_retry} = CycleFleet.create_assignment(second_retry_attrs)

    assert {:ok, _result} =
             complete_result(second_retry, "terminal-build-1-retry-2", "completed", %{
               completed_unit_ids: ["unit-1"]
             })

    [original, retry, second_retry]
  end

  defp complete_builders(scope, inventory_count) do
    for index <- 1..15 do
      units = Enum.map([index * 2 - 1, index * 2], &"unit-#{&1}")

      outcomes =
        if index == 15 do
          %{stalled_unit_ids: ["unit-29"], excluded_unit_ids: ["unit-30"]}
        else
          %{completed_unit_ids: units}
        end

      create_completed_builder(scope, "build-#{index}", units, outcomes)
    end

    assert inventory_count == 30
  end

  defp create_completed_builder(
         scope,
         id,
         assigned_ids,
         outcomes,
         agent_type \\ "legendary-builder"
       ) do
    assert {:ok, assignment} =
             CycleFleet.create_assignment(
               assignment_attrs(scope, id, "build", agent_type, assigned_ids)
             )

    assert {:ok, _result} =
             complete_result(assignment, "terminal-#{id}", "completed", outcomes)
  end

  defp complete_result(assignment, key, status, payload) do
    payload =
      if assignment.phase == "build" and status == "completed" do
        outcomes =
          Map.merge(
            %{completed_unit_ids: [], stalled_unit_ids: [], excluded_unit_ids: []},
            payload
          )

        task = ensure_semantic_task!(assignment)
        Map.put(outcomes, :semantic_receipts, semantic_receipt_claims(assignment, task, outcomes))
      else
        payload
      end

    CycleFleet.record_result(assignment, key, %{
      status: status,
      evidence: "paper://results/#{key}",
      evidence_revision: "rev-1",
      payload: payload
    })
  end

  defp ensure_semantic_task!(assignment) do
    case Repo.get(AssignmentTask, assignment.id) do
      %AssignmentTask{task_id: task_id} ->
        Repo.get!(Document, task_id)

      nil ->
        wave = Repo.get!(Wave, assignment.cycle_wave_id)
        project = Repo.get!(Barkpark.Tenancy.Project, wave.project_id)
        {:ok, dataset} = Tenancy.get_or_create_dataset(project, "production")
        worker = "builder-#{assignment.assignment_id}"
        criteria = semantic_criteria(assignment.assignment_id)

        task =
          %Document{}
          |> Document.changeset(%{
            doc_id: "task.#{assignment.assignment_id}.#{System.unique_integer([:positive])}",
            type: "task",
            dataset: "production",
            title: "Semantic proof for #{assignment.assignment_id}",
            status: "draft",
            content: %{
              "kind" => "task",
              "lifecycle_status" => "done",
              "acceptance_criteria" => criteria,
              "claim" => %{"worker" => worker, "epoch" => 1}
            },
            rev: Ecto.UUID.generate(),
            workspace_id: assignment.workspace_id,
            project_id: wave.project_id,
            dataset_id: dataset.id
          })
          |> Repo.insert!()

        assert {:ok, _binding} = CycleFleet.bind_assignment_task(assignment, task.id)
        task
    end
  end

  defp semantic_criteria(id) do
    [
      %{
        "criterion" => "#{id} has verified evidence",
        "met" => true,
        "evidence" => "paper://criteria/#{id}"
      }
    ]
  end

  defp semantic_receipt_claims(assignment, task, outcomes) do
    content = task.content
    claim = Map.fetch!(content, "claim")
    wave = Repo.get!(Wave, assignment.cycle_wave_id)

    dispositions =
      Enum.reduce(
        [
          shipped: Map.get(outcomes, :completed_unit_ids, []),
          stalled: Map.get(outcomes, :stalled_unit_ids, []),
          excluded: Map.get(outcomes, :excluded_unit_ids, [])
        ],
        %{},
        fn {disposition, ids}, acc ->
          Enum.reduce(ids, acc, &Map.put(&2, &1, Atom.to_string(disposition)))
        end
      )

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
        "criteria" => semantic_criteria(assignment.assignment_id),
        "claim" => %{"worker" => claim["worker"], "epoch" => claim["epoch"]},
        "unit_id" => unit_id,
        "disposition" => Map.get(dispositions, unit_id)
      }
    end)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp restore_test_env(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore_test_env(key, value), do: Application.put_env(:barkpark, key, value)
end
