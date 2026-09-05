defmodule Barkpark.Tasks.CloseIdempotentReplayTest do
  @moduledoc """
  THE RETRY ARM (task-17224f58d3bda3bd) — a close whose write LANDED must not
  report failure.

  MEASURED 2026-09-02 by lead-triage-o: five closes each exited rc=6 printing
  `stale_claim` while the row was in fact closed, each with its own reason
  stored verbatim. The natural recovery makes it worse — a re-claim then fails
  `not_ready`, because the row is already closed — so a worker that trusts the
  exit code reports a correctly-closed row as uncloseable, and the campaign's
  interim rule became "read back before believing a bp write FAILED".

  THE MECHANISM. `do_close_txn`'s already-terminal guard returned
  `{:error, :stale_claim}` for ANY terminal row when no explicit `observed_rev`
  was passed. That is right for two DIFFERENT closers racing: without it the
  default-observed-rev CAS would let every caller "succeed" in turn. It was
  wrong for the SAME closer retrying — attempt 1 commits, its response is lost
  or times out under load, attempt 2 reads the now-terminal row and is told the
  write failed.

  RED-WITHOUT / GREEN-WITH. On origin/main the "replay" tests below return
  `{:error, :stale_claim}` — that is the defect. The "still loses the race"
  tests are GREEN on origin/main and must STAY green: an idempotency that
  cannot tell a retry from a genuine lost race is worse than the bug it cures.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.Close

  @dataset "production"

  # A real artifact — a PR number AND a 7-40 hex sha — so the close-artifact
  # gate (PDS-D291) is satisfied and the ONLY thing these tests can trip is the
  # already-terminal guard under test.
  @artifact "landed #14383 @ 63b89bef30 — one envelope reader"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
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

  # CLAIMED on purpose, and the lease is written into the fixture rather than
  # taken through `Tasks.claim_by_id/3`: this test is about what `close` does to
  # a row already in a given state, so the state is stated outright instead of
  # depending on the claim verb's own readiness predicate. The shape is the one
  # `Claim` writes — `worker`, `epoch`, `ts_iso` — and `apply_close_update/9`
  # stamps `closed_by` onto exactly this map, which is the authorship record the
  # replay predicate compares against.
  @epoch 1

  defp mk_claimed_task!(scope, worker) do
    doc_id = uniq("replay-task")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "in_progress",
            "claim" => %{
              "worker" => worker,
              "epoch" => @epoch,
              "ts_iso" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          }
        },
        @dataset,
        scope
      )

    {doc, @epoch}
  end

  defp mk_unclaimed_task!(scope) do
    doc_id = uniq("replay-bare")

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{"kind" => "task", "lifecycle_status" => "open"}
        },
        @dataset,
        scope
      )

    doc
  end

  defp stored(%Document{id: id}), do: Repo.get!(Document, id)

  # ─── The replay: the defect this row cures ──────────────────────────────

  describe "a second close by the SAME worker to the SAME status" do
    test "is a SUCCESS carrying the stored row, not stale_claim", %{scope: scope} do
      {doc, ep} = mk_claimed_task!(scope, "worker-replay")

      assert {:ok, %Document{}, :closed} =
               Close.close_with_receipt(doc.id, "worker-replay",
                 observed_epoch: ep,
                 reason: @artifact
               )

      # THE DEFECT. On origin/main this second call is {:error, :stale_claim}
      # and the caller reports a correctly-closed row as uncloseable.
      assert {:ok, %Document{} = replayed, :already_closed} =
               Close.close_with_receipt(doc.id, "worker-replay",
                 observed_epoch: ep,
                 reason: @artifact
               )

      assert %{"lifecycle_status" => "done"} = replayed.content
    end

    test "changes NOTHING — reason, closed_by and closed_at are byte-identical",
         %{scope: scope} do
      {doc, ep} = mk_claimed_task!(scope, "worker-replay")

      assert {:ok, _, :closed} =
               Close.close_with_receipt(doc.id, "worker-replay",
                 observed_epoch: ep,
                 reason: @artifact
               )

      before = stored(doc)

      # A DIFFERENT reason on the retry, deliberately: if the replay wrote, this
      # is where the first close's authorship and rationale would be silently
      # overwritten — trading one lie for another.
      assert {:ok, _, :already_closed} =
               Close.close_with_receipt(doc.id, "worker-replay",
                 observed_epoch: ep,
                 reason: "landed #99999 @ deadbeef1 — a reason that must NOT land"
               )

      after_replay = stored(doc)

      assert after_replay.content["close_reason"] == before.content["close_reason"]
      assert after_replay.content["claim"]["closed_by"] == before.content["claim"]["closed_by"]
      assert after_replay.content["claim"]["closed_at"] == before.content["claim"]["closed_at"]
      assert after_replay.rev == before.rev, "a replay must not bump the rev"
      # Non-vacuity: the fixture really did store the first reason, so the
      # equalities above are comparing something.
      assert before.content["close_reason"] == @artifact
      assert before.content["claim"]["closed_by"] == "worker-replay"
    end

    test "close/3 keeps its two-tuple contract for every existing caller",
         %{scope: scope} do
      {doc, ep} = mk_claimed_task!(scope, "worker-replay")

      assert {:ok, %Document{}} =
               Tasks.close(doc.id, "worker-replay", observed_epoch: ep, reason: @artifact)

      assert {:ok, %Document{}} =
               Tasks.close(doc.id, "worker-replay", observed_epoch: ep, reason: @artifact)
    end
  end

  # ─── The race: still refused, and that is the point ─────────────────────

  describe "a terminal row that is NOT this worker's own replay" do
    test "closed by a DIFFERENT worker still loses the race", %{scope: scope} do
      {doc, ep} = mk_claimed_task!(scope, "worker-first")

      assert {:ok, _, :closed} =
               Close.close_with_receipt(doc.id, "worker-first",
                 observed_epoch: ep,
                 reason: @artifact
               )

      assert {:error, :stale_claim} =
               Close.close_with_receipt(doc.id, "worker-second",
                 observed_epoch: ep,
                 reason: @artifact,
                 holder_override: "second closer racing the first"
               )
    end

    test "closed to a DIFFERENT status still loses the race", %{scope: scope} do
      {doc, ep} = mk_claimed_task!(scope, "worker-replay")

      assert {:ok, _, :closed} =
               Close.close_with_receipt(doc.id, "worker-replay",
                 observed_epoch: ep,
                 reason: @artifact
               )

      # Same worker, but asking for `cancelled` on a row stored `done` is a
      # different intent, not a retry of this one.
      assert {:error, :stale_claim} =
               Close.close_with_receipt(doc.id, "worker-replay",
                 observed_epoch: ep,
                 lifecycle_status: "cancelled",
                 reason: @artifact
               )
    end

    test "a never-claimed row has no closed_by to compare, so it still refuses",
         %{scope: scope} do
      doc = mk_unclaimed_task!(scope)

      assert {:ok, _, :closed} =
               Close.close_with_receipt(doc.id, "worker-replay",
                 observed_epoch: 1,
                 reason: @artifact
               )

      # No claim map means no authorship record. Answering `{:ok, …}` to an
      # unidentifiable second caller would hand a success receipt to whoever
      # asked last, so this keeps the old refusal.
      assert {:error, :stale_claim} =
               Close.close_with_receipt(doc.id, "worker-replay",
                 observed_epoch: 1,
                 reason: @artifact
               )
    end
  end
end
