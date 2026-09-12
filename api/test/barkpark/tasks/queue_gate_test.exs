defmodule Barkpark.Tasks.QueueGateTest do
  use ExUnit.Case, async: true

  alias Barkpark.Tasks
  alias Barkpark.Tasks.{QueueGate, Validation, WorkDigest}
  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

  @base %{"kind" => "task", "lifecycle_status" => "open"}

  # A lease granted just now, and one granted an hour before the TTL boundary.
  # Both COMPUTED — a frozen literal in a liveness fixture is a fixture with an
  # expiry date on it.
  defp fresh_ts, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp expired_ts do
    DateTime.utc_now()
    |> DateTime.add(-(QueueGate.lease_ttl_seconds() + 3600), :second)
    |> DateTime.to_iso8601()
  end

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

  test "a CLOSED claim is not live — a reopened row is executable for a NEW worker" do
    # The exact shape `close` leaves behind: worker KEPT, closed_by + closed_at
    # stamped (close.ex "Stamp close metadata into the claim lease"), and then
    # `Stage` reopens `done → open` without touching `content.claim` at all.
    reopened = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "claim" => %{
        "worker" => "worker-a",
        "epoch" => 3,
        "ts_iso" => "2026-07-26T18:00:00Z",
        "closed_by" => "worker-a",
        "closed_at" => "2026-07-26T18:29:53Z"
      }
    }

    # RED BEFORE: both of these were "foreign_claimed"/false, forever.
    assert Tasks.execution_class(reopened, "worker-b") == "executable"
    assert QueueGate.executable?(reopened, "worker-b")

    # The residual holder is not privileged over a contender either.
    assert Tasks.execution_class(reopened, "worker-a") == "executable"

    # A persisted gate is still honoured once the dead claim stops shadowing it.
    parked =
      put_in(reopened["queue_gate"], %{"version" => 1, "state" => "parked", "reason" => "later"})

    assert Tasks.execution_class(parked, "worker-b") == "parked"
    refute QueueGate.executable?(parked, "worker-b")

    # closed_at ALONE is enough (a lease killed without a closer name).
    at_only = update_in(reopened["claim"], &Map.delete(&1, "closed_by"))
    assert Tasks.execution_class(at_only, "worker-b") == "executable"

    # And closed_by ALONE is enough.
    by_only = update_in(reopened["claim"], &Map.delete(&1, "closed_at"))
    assert Tasks.execution_class(by_only, "worker-b") == "executable"
  end

  test "a LIVE claim still derives foreign_claimed for other workers" do
    # Guard against over-widening: no close stamp, blank close stamps, and the
    # in_progress lease all stay foreign to a contender.
    #
    # `ts_iso` is COMPUTED, not the frozen "2026-07-26T18:00:00Z" this fixture
    # used to carry. That literal was already ~6 weeks in the past when
    # `live_claim_worker/1` learned about lease expiry, so a fixture named LIVE
    # was describing a corpse — and this whole test would have gone vacuous the
    # other way (foreign_claimed for a dead lease) had it been left alone.
    live = %{
      "kind" => "task",
      "lifecycle_status" => "in_progress",
      "claim" => %{"worker" => "worker-a", "epoch" => 1, "ts_iso" => fresh_ts()}
    }

    assert Tasks.execution_class(live, "worker-b") == "foreign_claimed"
    refute QueueGate.executable?(live, "worker-b")
    assert Tasks.execution_class(live, "worker-a") == "executable"
    assert QueueGate.executable?(live, "worker-a")

    for blank <- ["", "   "] do
      blanked =
        update_in(live["claim"], &Map.merge(&1, %{"closed_at" => blank, "closed_by" => blank}))

      assert Tasks.execution_class(blanked, "worker-b") == "foreign_claimed"
      refute QueueGate.executable?(blanked, "worker-b")
    end

    nils = update_in(live["claim"], &Map.merge(&1, %{"closed_at" => nil, "closed_by" => nil}))
    assert Tasks.execution_class(nils, "worker-b") == "foreign_claimed"
  end

  test "an EXPIRED lease is not a live claim — residue never reads foreign_claimed" do
    # The population this exists for: `bp task stage <id> open` moves a row out
    # of `in_progress` WITHOUT touching `content.claim`, and `TtlSweeper` only
    # ever selects `in_progress` rows — so this map is never blanked by anybody
    # and its holder's name outlives the lease permanently.
    residue = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "claim" => %{"worker" => "worker-a", "epoch" => 3, "ts_iso" => expired_ts()}
    }

    # RED BEFORE THE FIX: "foreign_claimed" / false. A six-day-dead claim was
    # LIVE, and the module's own @doc said liveness was checked.
    assert Tasks.execution_class(residue, "worker-b") == "executable"
    assert QueueGate.executable?(residue, "worker-b")
    refute QueueGate.claim_lease_live?(residue)

    # The arity-1 meaning is UNCHANGED and deliberate — "from no particular
    # worker's perspective, somebody else holds this". A dead lease is nobody.
    assert Tasks.execution_class(residue) == "executable"

    # An author's gate is still honoured once the dead claim stops shadowing it,
    # and it is the gate state — not `foreign_claimed` — that a reader is told.
    gated = put_in(residue["queue_gate"], %{"version" => 1, "state" => "parked", "reason" => "l"})
    assert Tasks.execution_class(gated, "worker-b") == "parked"
    refute QueueGate.executable?(gated, "worker-b")
  end

  test "the lease predicate FAILS CLOSED on an absent or unparseable ts_iso" do
    # It can only ever DOWNGRADE a holder to residue, so an unprovable case
    # keeps the protective answer. A parse bug that failed OPEN would hand one
    # lane another lane's row — worse than the bug being fixed.
    for ts <- [nil, "", "not-a-timestamp", "2026-13-45T99:99:99Z", 1_234_567] do
      claim = %{"worker" => "worker-a", "epoch" => 1}
      claim = if is_nil(ts), do: claim, else: Map.put(claim, "ts_iso", ts)
      content = Map.put(@base, "claim", claim)

      assert QueueGate.claim_lease_live?(content),
             "ts_iso #{inspect(ts)} must fail CLOSED (live), it did not"

      assert Tasks.execution_class(content, "worker-b") == "foreign_claimed"
    end

    # And a claim map that is not a map at all cannot crash the predicate.
    assert QueueGate.claim_lease_live?(%{"claim" => "worker-a"})
    assert QueueGate.claim_lease_live?(nil)
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
