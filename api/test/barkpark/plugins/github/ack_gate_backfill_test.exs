defmodule Barkpark.Plugins.Github.AckGateBackfillTest do
  @moduledoc """
  THE ELEVEN PRE-GATE ROWS — born before the acknowledgement criterion existed,
  and until this change unreachable by every writer that has a `bp` verb.

  Re-derived live on 2026-09-16 (`bp github status`): the census is STILL
  eleven, `no_criterion: 11`, `open: 5`, `closed: 6`. Every one of them carries
  no `ack_gate` criterion, so `Acknowledgement.has_criterion?/1` is false on all
  eleven and there is nothing on the row to stamp with the comment URL once a
  maintainer answers the reporter.

  The row that governs this file demands each of them be given one BY HAND. The
  hand is the problem: the flag is the ONE machine signal
  (`Acknowledgement` — "recognised by `ack_gate => true` and by nothing else"),
  and no writer could mint it.

    * `Internal.seed_criterion/4` built the newborn entry from a fixed base
      `%{"criterion", "met", "evidence"}` and `apply_entry_update/2` then wrote
      only `met` / `evidence` / `attempts` — so any `ack_gate` key on the update
      was DROPPED on the floor.
    * `Stamp.build_update/4` never carried one either.

  A criterion seeded through the shipped surface therefore READ like an
  acknowledgement and was invisible to the gate: exactly the merge_gate lesson
  (a wording convention and a machine flag drifting apart) reproduced on the
  flag that was designed to avoid it.

  What this file pins:

    * `stamp --miss --ack-gate` on a criteria-less intake row seeds a criterion
      the census and the close gate RECOGNISE — `has_criterion?/1` true;
    * the same row then refuses a `done` close with `acknowledgement_unposted`;
    * WITHOUT the flag the same stamp seeds an ordinary, unflagged criterion —
      the control that keeps the fix from flagging everything it touches;
    * the flag is MINT-ONLY: an in-range stamp cannot add it to a criterion
      that already exists, and cannot clear one that carries it.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.Acknowledgement
  alias Barkpark.Tasks.{Close, Internal, Stamp}

  @dataset "production"
  @repo "FRIKKern/barkpark"

  setup do
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

  defp uniq_issue, do: 900_000 + System.unique_integer([:positive])

  # A PRE-GATE intake row: exactly the shape of the eleven — intake-born, and
  # with NO `acceptance_criteria` key at all.
  defp mk_pre_gate_row!(scope, criteria \\ nil) do
    number = uniq_issue()
    doc_id = "gh-#{number}"

    content =
      %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "labels" => ["src:github", "needs-human"],
        "github" => %{"repo" => @repo, "issue" => number, "state" => "intake"}
      }
      |> then(fn c ->
        if criteria, do: Map.put(c, "acceptance_criteria", criteria), else: c
      end)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "outsider report ##{number}", "content" => content},
        @dataset,
        scope
      )

    # A criteria-less row cannot even be CLAIMED without saying so out loud —
    # the criteria-stated fence is the FIRST thing standing between a
    # maintainer and the backfill, and the override is the honest way past it.
    claim_opts =
      if criteria,
        do: scope,
        else: scope ++ [criteria_unstated_override: "backfilling the pre-gate ack criterion"]

    {:ok, claimed} = Tasks.claim_by_id(doc_id, "w", claim_opts)
    {doc, number, claimed.content["claim"]["epoch"]}
  end

  describe "the backfill door (stamp --miss --ack-gate)" do
    test "seeds a criterion the gate RECOGNISES on a criteria-less intake row", %{scope: scope} do
      {task, number, epoch} = mk_pre_gate_row!(scope)

      refute Map.has_key?(Repo.get!(Document, task.id).content, "acceptance_criteria"),
             "fixture precondition: this is a pre-gate row — the key is genuinely absent"

      refute Acknowledgement.has_criterion?(Repo.get!(Document, task.id).content),
             "fixture precondition: nothing on the row records the obligation"

      text = Acknowledgement.criterion(@repo, number)["criterion"]

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: text,
                 ack_gate: true,
                 outcome: {:miss, "backfilled the reporter obligation onto a pre-gate row"}
               )

      assert [entry] = stamped.content["acceptance_criteria"]
      assert entry["criterion"] == text
      assert entry["met"] == false, "a seeded criterion is born unmet"
      assert entry["ack_gate"] == true

      assert Acknowledgement.has_criterion?(stamped.content),
             "the census and the close gate read the FLAG, never the wording"

      refute Acknowledgement.acknowledged?(stamped.content),
             "seeding the obligation is not discharging it"
    end

    test "the backfilled row then REFUSES a done close by name", %{scope: scope} do
      {task, number, epoch} = mk_pre_gate_row!(scope)
      text = Acknowledgement.criterion(@repo, number)["criterion"]

      assert {:ok, _} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: text,
                 ack_gate: true,
                 outcome: {:miss, "backfilled"}
               )

      reloaded = Repo.get!(Document, task.id)
      assert Acknowledgement.has_criterion?(reloaded.content)

      # The backfill itself changes `acceptance_criteria` under the claim, so the
      # work-digest fence 409s FIRST and the ack gate is never reached. That is
      # the fence doing its job, and it is the second thing standing between a
      # maintainer and this workflow: the close has to name the rev it observed.
      assert {:error, {:doc_changed_since_claim, rev, ["acceptance_criteria"]}} =
               Close.close(task.id, "w",
                 observed_epoch: reloaded.content["claim"]["epoch"],
                 lifecycle_status: "done"
               )

      assert {:error, {:acknowledgement_unposted, ^number}} =
               Close.close(task.id, "w",
                 observed_epoch: reloaded.content["claim"]["epoch"],
                 observed_rev: rev,
                 lifecycle_status: "done"
               )

      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "in_progress",
             "the refusal is a refusal, not a decoration on a close that landed"
    end

    test "CONTROL — without the flag the same stamp seeds an UNFLAGGED criterion", %{
      scope: scope
    } do
      {task, number, epoch} = mk_pre_gate_row!(scope)
      text = Acknowledgement.criterion(@repo, number)["criterion"]

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: text,
                 outcome: {:miss, "same wording, no flag asked for"}
               )

      assert [entry] = stamped.content["acceptance_criteria"]
      assert entry["criterion"] == text
      refute Map.has_key?(entry, "ack_gate")

      refute Acknowledgement.has_criterion?(stamped.content),
             "the wording is not the signal — this is the drift the flag exists to refuse"
    end
  end

  describe "the flag is MINT-ONLY" do
    test "an in-range stamp cannot add the flag to an existing criterion", %{scope: scope} do
      {task, _number, epoch} =
        mk_pre_gate_row!(scope, [
          %{"criterion" => "an ordinary bar", "met" => false, "evidence" => ""}
        ])

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: "an ordinary bar",
                 ack_gate: true,
                 outcome: {:miss, "trying to retro-flag a stored row"}
               )

      assert [entry] = stamped.content["acceptance_criteria"]
      refute Map.has_key?(entry, "ack_gate")
      refute Acknowledgement.has_criterion?(stamped.content)
    end

    test "a stamp on a FLAGGED criterion never clears the flag", %{scope: scope} do
      number = 123_456
      flagged = Acknowledgement.criterion(@repo, number)
      {task, _n, epoch} = mk_pre_gate_row!(scope, [flagged])

      assert {:ok, stamped} =
               Stamp.stamp(task.id, "w",
                 observed_epoch: epoch,
                 criterion: 0,
                 criterion_text: flagged["criterion"],
                 outcome: {:miss, "an attempt, not a release"}
               )

      assert [entry] = stamped.content["acceptance_criteria"]
      assert entry["ack_gate"] == true
      assert Acknowledgement.has_criterion?(stamped.content)
    end
  end

  describe "merge_criteria/2 — the seed clause directly" do
    test "ack_gate: true on a seed mints the flag; anything else does not" do
      base = %{"kind" => "task", "lifecycle_status" => "open"}

      assert {:ok, flagged} =
               Internal.merge_criteria(base, [
                 %{
                   "index" => 0,
                   "criterion" => "answer the reporter",
                   "met" => false,
                   "ack_gate" => true
                 }
               ])

      assert [%{"ack_gate" => true, "met" => false}] = flagged["acceptance_criteria"]

      for bogus <- [false, "true", 1, nil] do
        assert {:ok, plain} =
                 Internal.merge_criteria(base, [
                   %{
                     "index" => 0,
                     "criterion" => "answer the reporter",
                     "met" => false,
                     "ack_gate" => bogus
                   }
                 ])

        [entry] = plain["acceptance_criteria"]

        refute Map.has_key?(entry, "ack_gate"),
               "only the literal boolean true mints the flag (got #{inspect(bogus)})"
      end
    end
  end
end
