defmodule Barkpark.Tasks.ReleaseTest do
  @moduledoc """
  Unit tests for `Barkpark.Tasks.Release` — the voluntary unclaim (the
  on-demand twin of the TTL sweeper's reap).

  Covers:
    1. Happy path: the holder releases → lifecycle open, claim.worker nil,
       epoch bumped, released_by/released_at stamped, assignee CLEARED,
       a `task.released` mutation_event emitted.
    2. Holder-only: a non-holder (even with the right epoch) → :not_holder.
    3. Epoch fence: a stale epoch → :fenced_off.
    4. Only in-flight releases: an open task → {:not_in_progress, "open"}.
    5. Not-found id → :not_found.
    6. Release-then-reclaim keeps the epoch monotonic.
    7. Regression: a MISSING observed_epoch raises loudly (KeyError) and a
       blank (nil) one is fenced off — never a silent exit-0 no-op.
    8. Ruling-pin: release ALWAYS lands "open", even for a blocked-born
       task (deterministic landing, NOT a pre-claim restore).
    9. task-7674bdd9964d953f — the released claim carries no SUPERSEDED lapse
       timestamp, and a genuine lapse that was never released keeps its own.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Tasks.{Release, TtlSweeper}

  @dataset "production"

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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp claimed_task!(scope, worker) do
    doc_id = uniq("rel")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
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
        @dataset,
        scope
      )

    {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, worker, scope)
    claimed
  end

  defp epoch_of(doc), do: get_in(Repo.get!(Document, doc.id).content, ["claim", "epoch"])

  # Write ONE key into the stored claim map without going through a verb —
  # used to seed a claim shape the engine no longer produces on its own.
  defp put_claim_key!(doc, key, value) do
    claim = Map.put(doc.content["claim"] || %{}, key, value)
    new_content = Map.put(doc.content, "claim", claim)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: new_content])

    Repo.get!(Document, doc.id)
  end

  # Age the live claim past the lease TTL WITHOUT touching worker or epoch, so
  # the row the TTL sweeper reaps is the one the test claimed.
  defp age_live_claim!(doc, seconds_ago) do
    iso = DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.to_iso8601()
    claim = Map.put(doc.content["claim"] || %{}, "ts_iso", iso)
    new_content = Map.put(doc.content, "claim", claim)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: new_content])

    Repo.get!(Document, doc.id)
  end

  describe "release/3" do
    test "the holder releases: open, worker cleared, epoch bumped, assignee gone, event emitted",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      assert {:ok, released} = Release.release(doc.id, "w-hold", observed_epoch: epoch)

      content = Repo.get!(Document, doc.id).content
      assert content["lifecycle_status"] == "open"
      assert get_in(content, ["claim", "worker"]) == nil
      assert get_in(content, ["claim", "epoch"]) == epoch + 1
      assert get_in(content, ["claim", "released_by"]) == "w-hold"
      assert is_binary(get_in(content, ["claim", "released_at"]))
      refute Map.has_key?(content, "assignee")
      assert released.rev != doc.rev

      assert Repo.exists?(
               from(e in MutationEvent,
                 where: e.doc_id == ^doc.doc_id and e.mutation == "task.released"
               )
             )
    end

    test "a non-holder is refused even with the right epoch", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      assert {:error, :not_holder} = Release.release(doc.id, "w-thief", observed_epoch: epoch)
      assert get_in(Repo.get!(Document, doc.id).content, ["claim", "worker"]) == "w-hold"
    end

    test "a stale epoch is fenced off", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      assert {:error, :fenced_off} = Release.release(doc.id, "w-hold", observed_epoch: epoch - 1)
    end

    test "only an in-flight task can be released", %{scope: scope} do
      doc_id = uniq("rel-open")

      {:ok, doc} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
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
          @dataset,
          scope
        )

      assert {:error, {:not_in_progress, "open"}} =
               Release.release(doc.id, "anyone", observed_epoch: 1)
    end

    test "an unknown id is :not_found" do
      assert {:error, :not_found} =
               Release.release("00000000-0000-0000-0000-000000000099", "w", observed_epoch: 1)
    end

    # REGRESSION GUARD: the epoch fence must fail LOUDLY when the caller
    # forgets (or blanks) observed_epoch. `Keyword.fetch!/2` raising here is
    # the contract — a silent exit-0 no-op would let a walk-away skip the
    # fence entirely. If this test starts failing, someone softened the
    # fetch; do not "fix" it by defaulting the epoch.
    test "a missing observed_epoch raises loudly and leaves the claim intact", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      assert_raise KeyError, fn -> Release.release(doc.id, "w-hold") end
      assert_raise KeyError, fn -> Release.release(doc.id, "w-hold", []) end

      content = Repo.get!(Document, doc.id).content
      assert content["lifecycle_status"] == "in_progress"
      assert get_in(content, ["claim", "worker"]) == "w-hold"
    end

    test "a blank (nil) observed_epoch is fenced off, never a silent no-op", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      assert {:error, :fenced_off} = Release.release(doc.id, "w-hold", observed_epoch: nil)

      content = Repo.get!(Document, doc.id).content
      assert content["lifecycle_status"] == "in_progress"
      assert get_in(content, ["claim", "worker"]) == "w-hold"
    end

    # RULING PIN (task-lifecycle-visibility wave, 2026-07-21): release lands
    # "open" DETERMINISTICALLY — it is not a restore of the pre-claim status.
    # This is the RED probe inverted: a blocked-born task that is claimed and
    # then released must land "open", because no pre-claim snapshot exists
    # anywhere (claim.ex keeps none) and the TtlSweeper reap twin makes the
    # same landing. See the doctrine comment in release.ex.
    test "a blocked-born task claims then releases to open — the always-open ruling",
         %{scope: scope} do
      doc_id = uniq("rel-blocked")

      {:ok, doc} =
        Content.create_document(
          "task",
          %{
            "doc_id" => doc_id,
            "title" => doc_id,
            "content" => %{
              "kind" => "task",
              "acceptance_criteria" => [
                %{
                  "criterion" => "the fixture states its bar",
                  "met" => true,
                  "evidence" => "fixture"
                }
              ],
              "lifecycle_status" => "blocked"
            }
          },
          @dataset,
          scope
        )

      {:ok, _claimed} = Tasks.claim_by_id(doc.doc_id, "w-hold", scope)
      epoch = epoch_of(doc)

      assert {:ok, _} = Release.release(doc.id, "w-hold", observed_epoch: epoch)

      content = Repo.get!(Document, doc.id).content
      assert content["lifecycle_status"] == "open"
      assert get_in(content, ["claim", "worker"]) == nil
    end

    test "release-then-reclaim keeps the epoch monotonic", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      {:ok, _} = Release.release(doc.id, "w-hold", observed_epoch: epoch)
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-next", scope)

      assert epoch_of(doc) > epoch + 1 or epoch_of(doc) == epoch + 2
      assert get_in(Repo.get!(Document, doc.id).content, ["claim", "worker"]) == "w-next"
    end
  end

  # ─── The stranded-claim deadlock (task-f07ead0c1f8025bb) ────────────────────
  #
  # RED BEFORE THE FIX: every assertion after the `stage` call reproduces the
  # filed deadlock. `Release.release/3` returned `{:error, {:not_in_progress,
  # "open"}}`, so this describe block fails on the pre-fix tree.
  describe "a STRANDED claim (lifecycle open, claim.worker still set)" do
    test "is reachable through a LEGAL stage, and only release can now free it",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-dead")
      epoch = epoch_of(doc)

      # THE PATH (row criterion 2): `stage` legally moves in_progress → open
      # (Transitions D7) and deliberately never touches content.claim. Nothing
      # here is a hack — this is the sanctioned reopen verb doing its job.
      assert {:ok, _} = Tasks.stage(doc.id, "open")

      stranded = Repo.get!(Document, doc.id).content
      assert stranded["lifecycle_status"] == "open"
      assert get_in(stranded, ["claim", "worker"]) == "w-dead"
      assert get_in(stranded, ["claim", "epoch"]) == epoch

      # The OTHER two verbs still refuse, exactly as filed — the deadlock is
      # that TOGETHER they left no exit, not that any one of them is wrong.
      assert {:error, :not_ready} = Tasks.claim_by_id(doc.doc_id, "w-rescuer", scope)

      assert {:error, {:not_in_progress, "open"}} =
               Tasks.stamp(doc.id, "w-rescuer",
                 observed_epoch: epoch,
                 criterion: 0,
                 outcome: {:miss, "cannot stamp a stranded row"}
               )

      # THE FIX (remedy A): a bystander frees it, WITHOUT impersonating the
      # dead holder. This is the line that reds on today's main.
      assert {:ok, _} = Release.release(doc.id, "w-rescuer", observed_epoch: epoch)

      freed = Repo.get!(Document, doc.id).content
      assert freed["lifecycle_status"] == "open"
      assert get_in(freed, ["claim", "worker"]) == nil
      assert get_in(freed, ["claim", "epoch"]) == epoch + 1
      # The attribution gap closes: released_by names the ACTOR, not the corpse.
      assert get_in(freed, ["claim", "released_by"]) == "w-rescuer"

      # …and the row is claimable again by anyone.
      assert {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-rescuer", scope)
    end

    test "the mutation event records BOTH the freed holder and the actor", %{scope: scope} do
      doc = claimed_task!(scope, "w-dead")
      epoch = epoch_of(doc)
      {:ok, _} = Tasks.stage(doc.id, "open")

      assert {:ok, _} = Release.release(doc.id, "w-rescuer", observed_epoch: epoch)

      ev =
        Repo.one!(
          from(e in MutationEvent,
            where: e.doc_id == ^doc.doc_id and e.mutation == "task.released"
          )
        )

      released = get_in(ev.document, ["released"])
      assert released["previous_worker"] == "w-dead"
      assert released["released_by"] == "w-rescuer"
      assert released["stranded_open"] == true
    end

    test "the epoch fence still applies to a stranded row", %{scope: scope} do
      doc = claimed_task!(scope, "w-dead")
      epoch = epoch_of(doc)
      {:ok, _} = Tasks.stage(doc.id, "open")

      assert {:error, :fenced_off} =
               Release.release(doc.id, "w-rescuer", observed_epoch: epoch - 1)
    end

    # PRESERVATION (row criterion 5, the half release owns): loosening the
    # lifecycle gate must NOT loosen the holder gate on a LIVE lease. A
    # bystander walking away with someone's in-flight claim is still refused.
    test "a LIVE in_progress lease is still holder-only", %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      assert {:error, :not_holder} = Release.release(doc.id, "w-thief", observed_epoch: epoch)
    end

    # PRESERVATION: an open row with NO holder is still a no-op target. The
    # new branch keys on the HOLDER, not on the lifecycle alone.
    test "an open row with a released (vacant) claim is still {:not_in_progress, \"open\"}",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)
      {:ok, _} = Release.release(doc.id, "w-hold", observed_epoch: epoch)

      # claim.worker is nil but the claim MAP survives with released_at —
      # the exact shape task-eb2b6170e19f1611 measured on the live board.
      content = Repo.get!(Document, doc.id).content
      assert is_map(content["claim"])
      assert get_in(content, ["claim", "released_at"]) != nil

      assert {:error, {:not_in_progress, "open"}} =
               Release.release(doc.id, "anyone", observed_epoch: epoch + 1)
    end
  end

  # ── task-7674bdd9964d953f: a released claim describes ONE reason ───────────
  #
  # THE INVARIANT, stated as the writer's job: `claim.expired_at` means "this
  # lease LAPSED, at this time". After a RELEASE the row is open because a
  # worker walked away, so a lapse timestamp on the stored claim describes a
  # SUPERSEDED event. `Release.apply_release_update/2` therefore deletes it,
  # unconditionally, exactly as it already deletes `resources`. Contrapositive,
  # equally load-bearing: a lease that genuinely lapsed and was NEVER released
  # keeps its `expired_at` — the delete belongs to the release verb, not to
  # the field.
  #
  # WHAT THE FILING GOT WRONG, measured here with the real verbs: it claimed
  # the stale shape arises from REAP -> RE-CLAIM -> RELEASE because the release
  # merges into "the existing claim". The merge is real, but the claim it
  # merges into is not the reaped one: `Tasks.Claim.do_claim_resolved/7` builds
  # `new_claim` as a FRESH map literal, so a re-claim already drops
  # `expired_at` (and `previous_worker`, `released_at`, `released_by`) before
  # any release can carry it forward. That is pinned below as its own test, so
  # the day claim.ex switches to a merge the pin reds instead of the fix
  # silently becoming load-bearing without anyone noticing.
  #
  # The fix is therefore STRUCTURAL, not a repair of a live production path:
  # the invariant now holds at the release writer for ANY claim map handed to
  # it — a hand-patched row (`bp doc patch`), a row written by an older
  # engine, or a future claim path that merges. RED-WITHOUT/GREEN-WITH:
  # deleting `|> Map.delete("expired_at")` from `apply_release_update/2` reds
  # "a claim carrying a lapse timestamp loses it when the lease is RELEASED"
  # and nothing else in this file.
  describe "release/3 and claim.expired_at (task-7674bdd9964d953f)" do
    test "a claim carrying a lapse timestamp loses it when the lease is RELEASED",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")

      # Seed the shape the gate compensates for: a live claim that still
      # carries a reap's `expired_at`. Seeded on purpose — see the measured
      # finding above: no engine verb currently produces it, which is exactly
      # why the invariant must live in the writer and not in the caller.
      lapse = "2026-07-30T10:00:00.000000Z"
      seeded = put_claim_key!(doc, "expired_at", lapse)
      before_release = seeded.content["claim"]

      assert before_release["expired_at"] == lapse,
             "BEFORE: the fixture did not carry a lapse timestamp, so this test proves nothing"

      assert before_release["worker"] == "w-hold"

      assert {:ok, _} =
               Release.release(doc.id, "w-hold", observed_epoch: before_release["epoch"])

      after_release = Repo.get!(Document, doc.id).content["claim"]

      assert is_binary(after_release["released_at"])
      assert after_release["released_by"] == "w-hold"
      assert after_release["worker"] == nil

      refute Map.has_key?(after_release, "expired_at"), """
      a RELEASED claim still carries a lapse timestamp:

        before release: #{inspect(before_release)}
        after release:  #{inspect(after_release)}

      The row is open because a worker walked away, not because a lease
      lapsed. Leaving the field means every reader has to compare
      released_at against expired_at to recover which reason is current.
      """

      # SCOPE FENCE: exactly ONE field goes. The CAS epoch rides on the merge
      # and must still bump; nothing else the claim held is tidied away.
      assert after_release["epoch"] == before_release["epoch"] + 1
      assert after_release["work_digest"] == before_release["work_digest"]
    end

    test "a lease that lapsed and was NEVER released keeps its expired_at (control)",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-walked-off")
      _aged = age_live_claim!(doc, 7200)

      assert {:ok, %{swept: swept}} = TtlSweeper.perform(%Oban.Job{})
      assert swept >= 1, "the sweeper reaped nothing, so this control measured nothing"

      claim = Repo.get!(Document, doc.id).content["claim"]

      assert is_binary(claim["expired_at"]),
             "the fix erased a lapse timestamp that legitimately describes the row: #{inspect(claim)}"

      assert claim["previous_worker"] == "w-walked-off"
      assert claim["worker"] == nil
      refute Map.has_key?(claim, "released_at")
    end

    test "a plain claim -> release (never reaped) has no expired_at to begin with",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-hold")
      epoch = epoch_of(doc)

      refute Map.has_key?(Repo.get!(Document, doc.id).content["claim"], "expired_at")

      assert {:ok, _} = Release.release(doc.id, "w-hold", observed_epoch: epoch)

      claim = Repo.get!(Document, doc.id).content["claim"]
      assert is_binary(claim["released_at"])
      refute Map.has_key?(claim, "expired_at")
    end

    # THE MEASURED CORRECTION TO THE FILING, pinned. REAP -> RE-CLAIM -> RELEASE
    # with the real verbs end to end. The re-claim, not the release, is what
    # drops the reap's stamp today.
    test "a RE-CLAIM after a reap already drops expired_at — claim.ex writes a FRESH map",
         %{scope: scope} do
      doc = claimed_task!(scope, "w-first")
      _aged = age_live_claim!(doc, 7200)

      assert {:ok, %{swept: swept}} = TtlSweeper.perform(%Oban.Job{})
      assert swept >= 1, "the sweeper reaped nothing, so this test proves nothing"

      reaped = Repo.get!(Document, doc.id).content["claim"]
      assert is_binary(reaped["expired_at"])
      assert reaped["previous_worker"] == "w-first"

      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "w-second", scope)
      reclaimed = Repo.get!(Document, doc.id).content["claim"]

      assert reclaimed["worker"] == "w-second"

      refute Map.has_key?(reclaimed, "expired_at"), """
      claim.ex now CARRIES the reap's expired_at into the new lease:

        after reap:     #{inspect(reaped)}
        after re-claim: #{inspect(reclaimed)}

      The filing for task-7674bdd9964d953f assumed exactly this, and it was
      not true when the fix landed. It is true now, which makes
      apply_release_update/2's Map.delete("expired_at") the only thing
      standing between a released row and a superseded lapse timestamp.
      """

      refute Map.has_key?(reclaimed, "previous_worker")

      # …and the release after it is clean either way.
      assert {:ok, _} =
               Release.release(doc.id, "w-second", observed_epoch: reclaimed["epoch"])

      released = Repo.get!(Document, doc.id).content["claim"]
      assert is_binary(released["released_at"])
      refute Map.has_key?(released, "expired_at")
    end
  end
end
