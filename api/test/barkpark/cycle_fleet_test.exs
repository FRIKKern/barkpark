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

  alias Barkpark.CycleFleet
  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet.{AssignmentTask, BuildPlan, Profile, Wave}
  alias Barkpark.EpicFleet.{Assignment, Result}
  alias Barkpark.Tenancy

  setup do
    {workspace, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

    scope = %{
      workspace_id: workspace.id,
      project_id: nil,
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
      assert %{safe?: true} = migration.rollback_blockers()

      assert {:ok, _wave} = CycleFleet.open_wave(legendary_wave_attrs(scope, 1))
      assert %{safe?: false, cycle_waves: 1} = migration.rollback_blockers()

      complete_experiments(scope)
      assert {:ok, _plan} = CycleFleet.seal_build_plan(scope, build_plan_attrs(2))

      assert %{
               safe?: false,
               cycle_waves: 1,
               cycle_build_plans: 1,
               cycle_bound_assignments: 15
             } = migration.rollback_blockers()
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

      assert Repo.aggregate(Wave, :count) == 1
      assert Repo.aggregate(BuildPlan, :count) == 1
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
          content: %{"kind" => "task", "lifecycle_status" => "open"},
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
          content: %{"kind" => "task", "lifecycle_status" => "open"},
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
               CycleFleet.record_result(assignment, "valid-partition", %{
                 status: "completed",
                 evidence: "paper://valid-partition",
                 evidence_revision: "rev-1",
                 payload: typed_outcomes(["unit-1"], ["unit-2"], [])
               })
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
        Map.merge(
          %{completed_unit_ids: [], stalled_unit_ids: [], excluded_unit_ids: []},
          payload
        )
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

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
