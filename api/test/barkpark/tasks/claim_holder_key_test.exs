defmodule Barkpark.Tasks.ClaimHolderKeyTest do
  @moduledoc """
  task-371c506d42be02cd — `claim.worker_id` DOES NOT EXIST on a stored task row,
  and a holder/lapse check keyed on it reads nil everywhere.

  MEASURED on the live production ledger 2026-09-14: of 1133 rows, 199 carry a
  claim OBJECT and 934 carry `claim: null`. All 199 objects have the key
  `worker`; ZERO have `worker_id`. The union of every claim key seen across the
  whole population does not contain `worker_id` at all.

  `worker_id` is the REQUEST parameter name — the JSON body key of
  claim/pulse/release/stamp/close — never a key of the stored map. The writer is
  the authority: `Tasks.Claim` builds `%{"worker" => worker_id, ...}`, so the
  value goes IN under `worker_id` and comes back OUT under `worker`.

  ## What these tests have to prove, and in which direction

  A key-absence assertion is trivially vacuous: `Map.has_key?/2` returning false
  on a broken read is byte-identical to a real absence. Four arms, all required:

    * THE CONTROL PAIR (criterion 2) — the SAME read is taken on a HELD row and
      on an UNCLAIMED row and must give DIFFERENT answers. A test that only
      reads held rows cannot tell "no such field" from "not claimed", which is
      exactly how this stayed invisible. The discriminator is the PRESENCE OF
      THE CLAIM MAP, not a key inside it.
    * THE ABSENCE, with its positive control on the same call — `worker_id` is
      absent from the stored claim while `worker` is present, asserted through
      one `Map.has_key?/2` so a reader that answers false to everything fails
      the control.
    * THE DERIVATION, not an enumeration — `worker` is the ONLY key of the
      written claim whose value is the worker id. Which key is authoritative is
      computed from the row, so a rename is caught without updating a list.
    * THE DRIFT GUARD (criterion 3) — `Internal.check_holder/2` accepts under
      the value at `claim["worker"]` and REFUSES the same string presented at
      `claim["worker_id"]`. If a future change moves the writer's key or the
      gate's read, exactly one side moves first and this reds.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Internal
  alias Barkpark.{Repo, Tasks}

  @dataset "production"

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk!(scope) do
    doc_id = uniq("chk")

    content = %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "acceptance_criteria" => [
        %{"criterion" => "the holder key is named", "met" => false, "evidence" => ""}
      ]
    }

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # THE STORED ROW, never the returned struct: the whole point is what a reader
  # of `bp task show` / GET /v1/tasks/:doc_id sees. `claim` stays nil-able on
  # purpose — nil IS the unclaimed answer, and defaulting it to %{} here would
  # destroy the control.
  defp stored_claim(%Document{id: id}), do: Repo.get!(Document, id).content["claim"]

  describe "the control pair: held vs unclaimed" do
    test "one read gives DIFFERENT answers for a held row and an unclaimed row", %{scope: scope} do
      held = mk!(scope)
      unclaimed = mk!(scope)

      {:ok, _} = Tasks.claim_by_id(held.doc_id, "w-holder", scope)

      held_claim = stored_claim(held)
      unclaimed_claim = stored_claim(unclaimed)

      # The discriminator. If these were equal the rest of this file would be
      # measuring a broken reader, not the ledger.
      refute held_claim == unclaimed_claim,
             "the same read answered identically for a HELD and an UNCLAIMED row"

      assert is_map(held_claim), "a claimed row stored no claim map"

      assert is_nil(unclaimed_claim),
             "an unclaimed row stored a claim map: #{inspect(unclaimed_claim)}"

      # And the consequence for a caller: probing a KEY INSIDE the claim cannot
      # tell the two apart, because `worker_id` is nil on both. This is the
      # filed defect, reproduced as an equality.
      assert get_in(held.content, ["claim", "worker_id"]) ==
               get_in(unclaimed.content, ["claim", "worker_id"])

      assert is_nil(get_in(Repo.get!(Document, held.id).content, ["claim", "worker_id"])),
             "claim.worker_id is populated — this task's premise no longer holds, re-measure"

      # Whereas the SUPPORTED read discriminates.
      assert held_claim["worker"] == "w-holder"
    end
  end

  describe "the stored claim's holder key" do
    test "worker is present and worker_id is absent, through one call with its control",
         %{scope: scope} do
      doc = mk!(scope)
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-holder", scope)
      claim = stored_claim(doc)

      # Positive control FIRST: the same `Map.has_key?/2` must answer true for a
      # key that does exist, or the absence below proves nothing.
      assert Map.has_key?(claim, "worker"),
             "positive control failed: the stored claim has no `worker` key either — " <>
               "the reader is broken, not the field"

      refute Map.has_key?(claim, "worker_id"),
             "the stored claim grew a `worker_id` key: #{inspect(Map.keys(claim))}"
    end

    test "`worker` is DERIVED as the only key holding the worker id, not read off a list",
         %{scope: scope} do
      doc = mk!(scope)
      worker = uniq("w-unmistakable")
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, worker, scope)

      holder_keys =
        doc
        |> stored_claim()
        |> Enum.filter(fn {_k, v} -> v == worker end)
        |> Enum.map(&elem(&1, 0))

      assert holder_keys == ["worker"],
             "the claim names its holder under #{inspect(holder_keys)}, not [\"worker\"] — " <>
               "every reader keyed on `claim.worker` now reads nil"
    end
  end

  describe "the holder gate and the readback name the SAME key" do
    test "check_holder/2 accepts under claim[\"worker\"] and refuses it moved to \"worker_id\"",
         %{scope: scope} do
      doc = mk!(scope)
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-holder", scope)
      stored = Repo.get!(Document, doc.id)

      assert Internal.check_holder(stored, "w-holder") == :ok,
             "the gate refused the worker the writer stored — gate and writer disagree TODAY"

      assert Internal.check_holder(stored, "someone-else") == {:error, :not_holder}

      # The drift arm: the same holder string, moved to `worker_id`. If a future
      # change teaches the gate to read `worker_id`, this stops refusing and
      # reds — which is the point, because the writer would still be storing
      # `worker` and the two would have silently diverged.
      moved_claim =
        stored.content["claim"] |> Map.delete("worker") |> Map.put("worker_id", "w-holder")

      moved = %Document{stored | content: Map.put(stored.content, "claim", moved_claim)}

      assert Internal.check_holder(moved, "w-holder") == {:error, :not_holder},
             "check_holder/2 accepted a holder named under `worker_id` — the gate and the " <>
               "stored readback now name different keys"
    end
  end
end
