defmodule Barkpark.Tasks.QueueGateTest do
  use ExUnit.Case, async: true

  alias Barkpark.Tasks
  alias Barkpark.Tasks.{QueueGate, Validation, WorkDigest}
  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

  @base %{"kind" => "task", "lifecycle_status" => "open"}

  test "schema exposes only persistable version-1 states" do
    field = Enum.find(Tasks.task_schema().fields, &(&1["name"] == "queue_gate"))

    assert field["type"] == "composite"
    assert Enum.map(field["fields"], & &1["name"]) == ~w(version state reason evidence)

    assert Enum.find(field["fields"], &(&1["name"] == "state"))["options"] ==
             ~w(executable human_gated parked evidence_stalled)

    refute "foreign_claimed" in Tasks.queue_gate_states()
  end

  test "legacy Tasks default executable and valid states round trip normalized" do
    assert :ok = Validation.validate_task_content(@base)
    assert Tasks.execution_class(@base) == "executable"

    assert {:ok, %{"state" => "executable", "version" => 1}} =
             QueueGate.sanitize(%{version: 1, state: "executable"})

    for state <- ~w(human_gated parked) do
      gate = %{"version" => 1, "state" => state, "reason" => "  explicit reason  "}
      assert :ok = Validation.validate_task_content(Map.put(@base, "queue_gate", gate))
      assert {:ok, sanitized} = QueueGate.sanitize(gate)
      assert sanitized["reason"] == "explicit reason"
    end

    stalled = %{
      "version" => 1,
      "state" => "evidence_stalled",
      "reason" => "waiting for proof",
      "evidence" => "paper://proof"
    }

    assert :ok = Validation.validate_task_content(Map.put(@base, "queue_gate", stalled))
  end

  test "malformed, unknown, derived, and contradictory gates fail closed" do
    invalid = [
      nil,
      %{},
      %{"version" => 2, "state" => "parked", "reason" => "later"},
      %{"version" => 1, "state" => "foreign_claimed", "reason" => "worker-b"},
      %{"version" => 1, "state" => "unknown", "reason" => "later"},
      %{"version" => 1, "state" => "parked"},
      %{"version" => 1, "state" => "human_gated", "reason" => "  "},
      %{"version" => 1, "state" => "evidence_stalled", "reason" => "proof missing"},
      %{"version" => 1, "state" => "executable", "reason" => "contradiction"},
      %{"version" => 1, "state" => "executable", "evidence" => "contradiction"},
      %{"version" => 1, "state" => "parked", "reason" => "later", "command" => "no"}
    ]

    assert :ok = Validation.validate_task_content(@base)

    for gate <- Enum.drop(invalid, 1) do
      assert {:error, %{"queue_gate" => errors}} =
               Validation.validate_task_content(Map.put(@base, "queue_gate", gate))

      assert is_map(errors)
      assert map_size(errors) > 0
    end

    assert {:error, %{"queue_gate" => %{"value" => [_ | _]}}} =
             Validation.validate_task_content(Map.put(@base, "queue_gate", "parked"))
  end

  test "foreign claim is derived from live claim state and holder transitions are stable" do
    gated = %{
      "queue_gate" => %{"version" => 1, "state" => "parked", "reason" => "paused"},
      "claim" => %{"worker" => "worker-a", "epoch" => 3}
    }

    assert Tasks.execution_class(gated) == "foreign_claimed"
    assert Tasks.execution_class(gated, "worker-b") == "foreign_claimed"
    assert Tasks.execution_class(gated, "worker-a") == "parked"

    released = Map.delete(gated, "claim")
    assert Tasks.execution_class(released, "worker-b") == "parked"

    legacy_claimed = %{"claim" => %{"worker" => "worker-a"}}
    assert Tasks.execution_class(legacy_claimed, "worker-b") == "foreign_claimed"
    assert Tasks.execution_class(legacy_claimed, "worker-a") == "executable"
  end

  test "executable predicate admits only absent, null, or exact executable v1 gates" do
    assert QueueGate.executable?(%{})
    assert QueueGate.executable?(%{"queue_gate" => nil})
    assert QueueGate.executable?(%{"queue_gate" => %{"version" => 1, "state" => "executable"}})

    refute QueueGate.executable?(%{
             "queue_gate" => %{"version" => 1, "state" => "human_gated", "reason" => "approval"}
           })

    refute QueueGate.executable?(%{"queue_gate" => %{"version" => 2, "state" => "executable"}})
    refute QueueGate.executable?(nil)

    content = %{
      "queue_gate" => %{"version" => 1, "state" => "executable"},
      "claim" => %{"worker" => "holder"}
    }

    assert QueueGate.executable?(content, "holder")
    refute QueueGate.executable?(content, "contender")
  end

  test "Task API projection round trips the stored gate and derived execution class" do
    gate = %{"version" => 1, "state" => "human_gated", "reason" => "needs approval"}

    doc = %Document{
      id: Ecto.UUID.generate(),
      doc_id: "queue-gate-projection",
      type: "task",
      title: "Projection",
      status: "published",
      dataset: "production",
      rev: "r1",
      content: Map.merge(@base, %{"queue_gate" => gate})
    }

    rendered = Params.render_doc(doc)
    assert rendered.queue_gate == gate
    assert rendered.execution_class == "human_gated"

    claimed_content = Map.put(doc.content, "claim", %{"worker" => "worker-a"})

    assert Params.render_doc(%{doc | content: claimed_content}).execution_class ==
             "foreign_claimed"
  end

  test "queue gate edits participate in the claim work digest without changing legacy parity" do
    legacy = WorkDigest.field_digests("task", @base)
    refute Map.has_key?(legacy, "queue_gate")

    gated = Map.put(@base, "queue_gate", %{"version" => 1, "state" => "executable"})
    stored = WorkDigest.field_digests("task", gated)
    assert Map.has_key?(stored, "queue_gate")
    assert WorkDigest.changed_fields(stored, "task", gated) == []

    parked =
      Map.put(@base, "queue_gate", %{
        "version" => 1,
        "state" => "parked",
        "reason" => "paused"
      })

    assert WorkDigest.changed_fields(stored, "task", parked) == ["queue_gate"]
    assert WorkDigest.changed_fields(stored, "task", @base) == ["queue_gate"]
    assert WorkDigest.changed_fields(legacy, "task", gated) == ["queue_gate"]
  end
end
