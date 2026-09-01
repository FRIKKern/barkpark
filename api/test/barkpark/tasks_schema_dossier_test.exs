defmodule Barkpark.TasksSchemaDossierTest do
  @moduledoc """
  Task-dossier schema regression guards (the rich task schema redesign).

  Three hazard classes under test:

    1. **v2 parse guard** — the schema must PARSE as a v2 schema
       (`flat?/1 == false`). `Validation.validate_v2/3` falls back to the
       legacy flat validator when `parse/2` errors (fail-open by design),
       so a malformed field would silently disable the recursive walker
       rather than fail loudly. This test makes that loud.
    2. **Groups invariant** — once a schema declares `groups`, a field
       without a `"group"` key renders on NO Studio tab (silent vanish).
       Every field must carry a group that exists.
    3. **Engine safety** — load-bearing stored shapes must not drift:
       claim/history/history_summary stay opaque v1 object/array (no form
       input → byte-identical on Studio saves), the compactor's strippable
       markers stay undeclared, `worklog` never collides with the
       compactor-owned `history` key, and legacy/engine-written content
       still passes both the micro-validator and the v2 walker.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.Validation
  alias Barkpark.Tasks

  # The schema as the validation layer sees it after a DB round-trip /
  # serialization: a plain string-keyed map (a %SchemaDefinition{} struct is
  # not enumerable, so parse/2 wants the map form).
  defp schema_map do
    Tasks.task_schema()
    |> Map.from_struct()
    |> Map.drop([
      :__meta__,
      :workspace,
      :project,
      :dataset_entity,
      :id,
      :inserted_at,
      :updated_at
    ])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # A realistic legacy task: claimed, compacted, labeled — every key the
  # engine (claim/close/TTL/compactor/relabel/papers) writes today.
  defp legacy_engine_content do
    %{
      "kind" => "task",
      "lifecycle_status" => "done",
      "priority" => 1,
      "assignee" => "agent-7",
      "parent_id" => "drafts.task-root-1",
      "dependencies" => ["task-a"],
      "labels" => ["w7", "infra"],
      "papers" => ["unified-task-model"],
      "claim" => %{
        "worker" => "agent-7",
        "ts_iso" => "2026-06-01T10:00:00Z",
        "epoch" => 3,
        "closed_by" => "agent-7",
        "closed_at" => "2026-06-01T11:00:00Z"
      },
      "history" => [
        %{"kind" => "task.claimed", "ts" => "2026-06-01T10:00:00Z"},
        %{"kind" => "task.closed", "ts" => "2026-06-01T11:00:00Z"}
      ],
      "history_summary" => %{
        "event_count" => 12,
        "workers" => ["agent-7"]
      }
    }
  end

  describe "v2 parse guard (fail-open flat fallback must never engage)" do
    test "the task schema parses" do
      assert {:ok, parsed} = SchemaDefinition.parse(schema_map())
      assert parsed.name == "task"
    end

    test "the schema is v2 (flat?/1 == false) so the recursive walker runs" do
      {:ok, parsed} = SchemaDefinition.parse(schema_map())
      refute SchemaDefinition.flat?(parsed)
    end

    test "the v2 walker accepts legacy engine-written content" do
      assert {:ok, _} =
               Validation.validate(legacy_engine_content(), "Some legacy task", schema_map())
    end

    test "the v2 walker accepts a fully-populated dossier" do
      content =
        Map.merge(legacy_engine_content(), %{
          "description" => "Why this task exists.",
          "purpose" => %{
            "statement" => "Ship the dossier",
            "why" => "Readers need operational context",
            "endgame" => "Every task is self-explanatory",
            "importance" => %{"score" => 95, "reason" => "core workflow"},
            "relevance" => %{"score" => 90, "reason" => "active work"},
            "proof" => [
              %{"claim" => "Validated", "evidence" => "schema test", "source" => "ExUnit"}
            ]
          },
          "design" => "Approach sketch.",
          "design_doc" => "unified-task-model",
          "due_at" => "2026-06-20T12:00:00",
          "acceptance_criteria" => [
            %{"criterion" => "tests pass", "met" => true, "evidence" => "mix test green"}
          ],
          "estimate" => %{"size" => "m", "reason" => "two files"},
          "worklog" => [
            %{
              "ts" => "2026-06-01T10:30:00Z",
              "worker" => "agent-7",
              "kind" => "progress",
              "note" => "validator wired"
            }
          ],
          "blocked_reason" => "",
          "attachments" => ["media-abc123"],
          "outcome" => %{
            "summary" => "Shipped the schema.",
            "resolution" => "shipped",
            "actual_size" => "m",
            "commits" => ["abc1234"]
          },
          "close_reason" => "done per criteria",
          "retro" => "Estimate held."
        })

      assert {:ok, _} = Validation.validate(content, "Dossier task", schema_map())
    end
  end

  describe "groups invariant (a groupless field vanishes from the Studio editor)" do
    test "every field carries a group that exists in schema groups" do
      schema = Tasks.task_schema()
      group_names = MapSet.new(schema.groups, & &1["name"])

      for field <- schema.fields do
        assert field["group"],
               "field #{inspect(field["name"])} has no \"group\" — it would render on NO Studio tab"

        assert field["group"] in group_names,
               "field #{inspect(field["name"])} points at unknown group #{inspect(field["group"])}"
      end
    end

    test "every desk_groups filter targets content.lifecycle_status or is the all-chip" do
      schema = Tasks.task_schema()

      for desk <- schema.desk_groups do
        assert desk["filter"] == %{} or
                 Map.has_key?(desk["filter"], "content.lifecycle_status"),
               "desk chip #{inspect(desk["name"])} filters an unexpected path"
      end
    end
  end

  describe "engine safety (load-bearing stored shapes must not drift)" do
    test "claim/history stay opaque v1 types — no form input, byte-identical saves" do
      fields = Map.new(Tasks.task_schema().fields, &{&1["name"], &1})

      # v1 object/array render read-only JSON in Studio and emit NO form
      # input, so saves can never rewrite the fencing token or the
      # compactor tail. An editable composite here would be a corruption
      # vector.
      assert fields["claim"]["type"] == "object"
      assert fields["history"]["type"] == "array"
      assert fields["history_summary"]["type"] == "object"
      assert fields["dependencies"]["type"] == "array"
      assert fields["papers"]["type"] == "array"
    end

    test "the compactor's strippable markers stay UNDECLARED" do
      names = MapSet.new(Tasks.task_schema().fields, & &1["name"])

      # restore/2 strips these; declaring them would render editable text
      # inputs a human could corrupt (e.g. clearing the compaction
      # idempotence flag).
      for marker <- ~w(compacted_at compaction_snapshot_revision_id parent) do
        refute marker in names,
               "#{marker} must stay undeclared (compactor-owned, strippable)"
      end
    end

    test "worklog and history are distinct keys (compactor tail-replaces only history)" do
      names = Enum.map(Tasks.task_schema().fields, & &1["name"])
      assert "worklog" in names
      assert "history" in names
    end

    test "lifecycle_status options stay single-sourced from lifecycle_statuses/0" do
      field = Enum.find(Tasks.task_schema().fields, &(&1["name"] == "lifecycle_status"))
      assert field["type"] == "select"
      assert field["options"] == Tasks.lifecycle_statuses()
    end

    test "priority stays a number (ready sort casts ::int; select would store strings)" do
      field = Enum.find(Tasks.task_schema().fields, &(&1["name"] == "priority"))
      assert field["type"] == "number"
    end

    test "parent_id upgraded to reference with IDENTICAL persistence (bare doc-id string)" do
      field = Enum.find(Tasks.task_schema().fields, &(&1["name"] == "parent_id"))
      assert field["type"] == "reference"
      assert field["refType"] == "task"
    end

    test "design_doc is a single paper reference (the one shape ?expand= supports)" do
      field = Enum.find(Tasks.task_schema().fields, &(&1["name"] == "design_doc"))
      assert field["type"] == "reference"
      assert field["refType"] == "paper"
    end

    test "purpose is a structured, editable dossier rather than an opaque prose blob" do
      field = Enum.find(Tasks.task_schema().fields, &(&1["name"] == "purpose"))
      assert field["type"] == "composite"
      names = MapSet.new(field["fields"], & &1["name"])

      assert MapSet.new(~w(part_of impact statement why endgame importance relevance proof)) ==
               names
    end

    test "purpose why asks for causal mission rationale, not a criteria paraphrase" do
      purpose = Enum.find(Tasks.task_schema().fields, &(&1["name"] == "purpose"))
      why = Enum.find(purpose["fields"], &(&1["name"] == "why"))

      assert why["title"] == "Why this matters"
      assert why["description"] =~ "causal reason"
      assert why["description"] =~ "parent mission"
      assert why["description"] =~ "Do not restate"
      assert why["description"] =~ "acceptance criteria"
    end

    test "initial_values stays ABSENT (validate-before-merge; priority floor would re-rank ready)" do
      assert Tasks.task_schema().initial_values == %{}
    end
  end

  describe "micro-validator — dossier fields (shape-only-when-present)" do
    defp valid_base, do: %{"kind" => "task", "lifecycle_status" => "open"}

    test "accepts a content map with every dossier field well-shaped" do
      assert :ok =
               Tasks.validate_task_content(
                 Map.merge(valid_base(), %{
                   "description" => "d",
                   "design" => "d",
                   "design_doc" => "paper-1",
                   "due_at" => "2026-06-20T12:00:00",
                   "blocked_reason" => "waiting",
                   "close_reason" => "done",
                   "retro" => "fine",
                   "papers" => ["p1"],
                   "attachments" => ["m1"],
                   "labels" => ["a"],
                   "history" => [%{"kind" => "task.claimed"}],
                   "estimate" => %{"size" => "s"},
                   "outcome" => %{"summary" => "ok"},
                   "history_summary" => %{"event_count" => 1},
                   "worklog" => [%{"note" => "hi"}],
                   "acceptance_criteria" => [%{"criterion" => "c", "met" => false}]
                 })
               )
    end

    test "legacy W7-mirror labels (non-string elements) stay tolerated" do
      assert :ok = Tasks.validate_task_content(Map.put(valid_base(), "labels", [1, "two"]))
    end

    test "rejects non-string scalar dossier fields" do
      for key <- ~w(description design design_doc due_at blocked_reason close_reason retro) do
        result = Tasks.validate_task_content(Map.put(valid_base(), key, 42))

        assert match?({:error, _}, result),
               "expected #{key}=42 to be rejected, got #{inspect(result)}"

        {:error, errors} = result

        assert errors[key]
      end
    end

    test "rejects non-list worklog / acceptance_criteria and non-map elements" do
      for key <- ~w(worklog acceptance_criteria) do
        assert {:error, %{^key => _}} =
                 Tasks.validate_task_content(Map.put(valid_base(), key, "nope"))

        assert {:error, %{^key => _}} =
                 Tasks.validate_task_content(Map.put(valid_base(), key, ["not-a-map"]))
      end
    end

    test "rejects non-map estimate / outcome / history_summary" do
      for key <- ~w(estimate outcome history_summary) do
        assert {:error, %{^key => _}} =
                 Tasks.validate_task_content(Map.put(valid_base(), key, "nope"))
      end
    end

    test "rejects non-list labels / history" do
      for key <- ~w(labels history) do
        assert {:error, %{^key => _}} =
                 Tasks.validate_task_content(Map.put(valid_base(), key, "nope"))
      end
    end

    test "rejects papers / attachments lists with non-string entries" do
      for key <- ~w(papers attachments) do
        assert {:error, %{^key => _}} =
                 Tasks.validate_task_content(Map.put(valid_base(), key, ["ok", 42]))
      end
    end

    test "a minimal CLI create payload validates" do
      # The smallest useful create payload.
      assert :ok =
               Tasks.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "priority" => 2,
                 "description" => "from bd",
                 "labels" => ["scope"]
               })
    end
  end
end
