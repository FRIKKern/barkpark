defmodule Barkpark.Tasks.BackgroundBroadcastHonestyTest do
  @moduledoc """
  PDS-D451 — THE FIVE BACKGROUND WRITE ARMS BROADCAST THE STORED ROW.

  `receipt_honesty_test.exs` paid the nine reconstruct-after-CAS arms that hand
  a receipt back to an HTTP caller. FIVE MORE arms carry the byte-identical
  shape and never return anything to a caller at all — they announce through
  `Content.Broadcast` instead:

      fence.ex        Fence.add_dep/4              task.mutated
      ttl_sweeper.ex  TtlSweeper.sweep/1           task.lease_expired
      ttl_sweeper.ex  TtlSweeper.sweep_engagement/1 task.engagement_lapsed
      compactor.ex    Compactor.compact/1          task.compacted
      compactor.ex    Compactor.restore/2          task.compaction_restored

  Each ran a rev-fenced `Repo.update_all(set: [content:, rev:, updated_at:])`
  — which returns a ROW COUNT, never a row — and then RECONSTRUCTED the receipt
  as `%{doc | content: …, rev: …}`. `updated_at` is deliberately written to the
  DB and deliberately absent from the merge, so the announced struct carried the
  PREVIOUS write's timestamp.

  THE LEAK IS IN **TWO** FIELDS OF THE SAME MESSAGE, not one. `Content.Broadcast`
  reads `doc.updated_at` twice:

      msg.doc.updated_at              broadcast.ex — the `doc:` map
      msg.document["_updatedAt"]      broadcast.ex -> Envelope.render/3

  A differential that destructures only `doc: %{updated_at: …}` — the shape the
  existing receipt test uses, and the ONLY shape anywhere in the suite —
  structurally cannot fail on the second field. Every assertion here names BOTH,
  and reports the divergent field SET so a half-fix reads as a half-failure.

  `msg.rev`, `document["_rev"]` and `doc.content` were measured byte-equal on
  every arm before the fix: the CAS really does prove exactly one row took
  exactly this content. Only the timestamp lied — twice.

  THE 0-ROW ARMS ARE **THREE DISTINCT VALUES ACROSS FIVE ARMS**, and one of them
  is not an error atom at all:

      fence                 nil                      (bundle-absent sentinel)
      reap                  :skipped
      engagement lapse      :skipped
      compaction            :skipped
      restore               {:error, :stale_claim}

  They are defensive branches: every arm re-reads the row under its per-task
  `pg_advisory_xact_lock`, so no outside writer can lose the fence for it. They
  are driven here anyway, by bumping the row's `rev` from a telemetry hook that
  fires on the arm's OWN read — inside the arm's transaction, after the read it
  fenced on. That is a real 0-row CAS, executed, not a source reading.
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, Envelope, Revision}
  alias Barkpark.Tasks.{Compactor, Internal, TtlSweeper}

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

    # Deliberately NOT `Sandbox.mode(Repo, {:shared, self()})` — every arm under
    # test runs its transaction, and fires its broadcast, in THIS process, so the
    # checked-out connection is enough (same reasoning as receipt_honesty_test).
    %{scope: scope}
  end

  # ─── fixtures ─────────────────────────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk_task!(doc_id, scope, content_extra \\ %{}) do
    content =
      Map.merge(
        %{
          "kind" => "task",
          "acceptance_criteria" => [
            %{"criterion" => "the fixture states its bar", "met" => true, "evidence" => "fixture"}
          ],
          "lifecycle_status" => "open"
        },
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp iso_ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  # Backdate a claim's ts_iso so the reap sweep sees a dead lease without sleeping.
  defp age_claim!(%Document{} = doc, seconds_ago) do
    new_claim = Map.put(doc.content["claim"], "ts_iso", iso_ago(seconds_ago))
    new_content = Map.put(doc.content, "claim", new_claim)

    {1, _} =
      from(d in Document, where: d.id == ^doc.id)
      |> Repo.update_all(set: [content: new_content])

    Repo.get!(Document, doc.id)
  end

  defp gen_history(n) do
    base = DateTime.utc_now()

    for i <- 1..n do
      ts = base |> DateTime.add(i, :second) |> DateTime.to_iso8601()
      %{"kind" => "comment", "ts" => ts, "worker" => "worker-A", "body" => "event-#{i}"}
    end
  end

  defp mk_done_with_history!(doc_id, scope, n) do
    task = mk_task!(doc_id, scope)

    content =
      task.content
      |> Map.put("lifecycle_status", "done")
      |> Map.put("history", gen_history(n))

    {1, _} =
      from(d in Document, where: d.id == ^task.id)
      |> Repo.update_all(set: [content: content])

    Repo.get!(Document, task.id)
  end

  defp snapshot_revision!(doc_id) do
    Repo.one!(
      from r in Revision,
        where: r.doc_id == ^doc_id and r.action == ^Compactor.snapshot_action()
    )
  end

  defp subscribe!, do: Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:#{@dataset}")

  # ─── the differential ─────────────────────────────────────────────────────

  # THE assertion of this file. Both broadcast timestamp fields against the row
  # Postgres holds, with the divergent field SET named on failure — a fix that
  # pays one field and not the other fails here with the surviving field named.
  defp assert_broadcast_matches_stored!(msg, doc_uuid, pre_write_updated_at) do
    stored = Repo.get!(Document, doc_uuid)
    stored_rendered = Envelope.render(stored, nil, :internal)

    divergent =
      []
      |> then(fn acc ->
        if msg.doc.updated_at == stored.updated_at, do: acc, else: acc ++ ["doc.updated_at"]
      end)
      |> then(fn acc ->
        if msg.document["_updatedAt"] == stored_rendered["_updatedAt"],
          do: acc,
          else: acc ++ ["document._updatedAt"]
      end)

    assert divergent == [],
           """
           the broadcast shipped a timestamp the DB does not hold.
           divergent fields:      #{inspect(divergent)}
           doc.updated_at:        #{inspect(msg.doc.updated_at)}
           document._updatedAt:   #{inspect(msg.document["_updatedAt"])}
           stored updated_at:     #{inspect(stored.updated_at)}
           stored _updatedAt:     #{inspect(stored_rendered["_updatedAt"])}
           """

    # ABLE TO FAIL: the write really did move the timestamp, so equality above
    # is a measurement and not a tautology over an unchanged row.
    refute msg.doc.updated_at == pre_write_updated_at,
           "the broadcast is still carrying the PRE-write value — the reconstruction survived"

    # The CAS was honest all along on these: pin them so a future change to the
    # write shape cannot quietly move content/rev while nobody is looking.
    assert msg.doc.content == stored.content
    assert msg.rev == stored.rev
    assert msg.document["_rev"] == stored.rev
  end

  # ─── the 0-row driver ─────────────────────────────────────────────────────

  # Bump `doc_uuid`'s rev from a telemetry handler on the arm's own SELECT of
  # `documents` — same process, therefore same connection and same transaction,
  # therefore committed-visible to the arm's very next statement. The arm fenced
  # on the rev it read one statement earlier, so its CAS matches 0 rows. Every
  # documents SELECT is bumped while armed, so it does not matter how many reads
  # the arm does before the one it fences on.
  defp with_lost_fence(doc_uuid, fun) do
    test_pid = self()
    handler_id = {__MODULE__, :rev_bumper, System.unique_integer([:positive])}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == test_pid and meta[:source] == "documents" and
             is_binary(meta[:query]) and String.starts_with?(meta[:query], "SELECT") and
             Process.get(:bp_rev_bumper_busy) != true do
          Process.put(:bp_rev_bumper_busy, true)

          try do
            Repo.update_all(
              from(d in Document, where: d.id == ^doc_uuid),
              set: [rev: Internal.generate_rev()]
            )
          after
            Process.delete(:bp_rev_bumper_busy)
          end
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  # ─── ARM 1 — fence.ex, the edge-add epoch bump ────────────────────────────

  describe "ARM 1 — Fence.add_dep/4 (task.mutated)" do
    test "the fence broadcast carries the STORED updated_at in BOTH fields", %{scope: scope} do
      dependent = mk_task!(uniq("bg-fence-dep"), scope)
      blocker = mk_task!(uniq("bg-fence-blk"), scope)

      {:ok, _claimed} = Tasks.claim_by_id(dependent.doc_id, "w-bg-fence", scope)
      pre = Repo.get!(Document, dependent.id).updated_at

      subscribe!()
      assert {:ok, _edge} = Tasks.add_dep(dependent.id, blocker.id, :blocks)

      dependent_doc_id = dependent.doc_id

      assert_receive {:document_changed,
                      %{mutation: "task.mutated", doc_id: ^dependent_doc_id} = msg},
                     2_000

      assert_broadcast_matches_stored!(msg, dependent.id, pre)
    end

    test "a lost CAS is still the nil bundle-absent sentinel — the edge add still succeeds",
         %{scope: scope} do
      dependent = mk_task!(uniq("bg-fence-stale-dep"), scope)
      blocker = mk_task!(uniq("bg-fence-stale-blk"), scope)

      {:ok, claimed} = Tasks.claim_by_id(dependent.doc_id, "w-bg-fence", scope)
      epoch_before = claimed.content["claim"]["epoch"]

      subscribe!()

      # `nil` is NOT an error atom: `List.wrap(nil) == []` swallows it, so the
      # edge-adder is still never rejected, no broadcast is emitted, and the
      # holder's epoch is left exactly where it was.
      assert {:ok, _edge} =
               with_lost_fence(dependent.id, fn ->
                 Tasks.add_dep(dependent.id, blocker.id, :blocks)
               end)

      assert Repo.get!(Document, dependent.id).content["claim"]["epoch"] == epoch_before
      refute_receive {:document_changed, %{mutation: "task.mutated"}}, 200
    end
  end

  # ─── ARM 2 — ttl_sweeper.ex, the lease reap ───────────────────────────────

  describe "ARM 2 — TtlSweeper.sweep/1 (task.lease_expired)" do
    test "the reap broadcast carries the STORED updated_at in BOTH fields", %{scope: scope} do
      task = mk_task!(uniq("bg-reap"), scope)
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "w-bg-reap", scope)
      aged = age_claim!(claimed, 600)
      pre = aged.updated_at

      subscribe!()
      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep(300)

      task_doc_id = task.doc_id
      kind = TtlSweeper.event_kind()

      assert_receive {:document_changed, %{mutation: ^kind, doc_id: ^task_doc_id} = msg}, 2_000

      assert_broadcast_matches_stored!(msg, task.id, pre)
    end

    test "a lost CAS is still :skipped", %{scope: scope} do
      task = mk_task!(uniq("bg-reap-stale"), scope)
      {:ok, claimed} = Tasks.claim_by_id(task.doc_id, "w-bg-reap", scope)
      _ = age_claim!(claimed, 600)

      assert %{swept: 0, skipped: 1} =
               with_lost_fence(task.id, fn -> TtlSweeper.sweep(300) end)

      # The lease survived — a lost fence must not half-reap the row.
      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "in_progress"
    end
  end

  # ─── ARM 3 — ttl_sweeper.ex, the engagement lapse ─────────────────────────

  describe "ARM 3 — TtlSweeper.sweep_engagement/1 (task.engagement_lapsed)" do
    test "the lapse broadcast carries the STORED updated_at in BOTH fields", %{scope: scope} do
      engagement = %{"object" => "research", "holder" => "cycle-bg", "ts" => iso_ago(600)}

      task =
        mk_task!(uniq("bg-lapse"), scope, %{
          "lifecycle_status" => "researching",
          "engagement" => engagement
        })

      pre = task.updated_at

      subscribe!()
      assert %{swept: 1, skipped: 0} = TtlSweeper.sweep_engagement(300)

      task_doc_id = task.doc_id
      kind = TtlSweeper.engagement_event_kind()

      assert_receive {:document_changed, %{mutation: ^kind, doc_id: ^task_doc_id} = msg}, 2_000

      assert_broadcast_matches_stored!(msg, task.id, pre)
    end

    test "a lost CAS is still :skipped", %{scope: scope} do
      engagement = %{"object" => "research", "holder" => "cycle-bg", "ts" => iso_ago(600)}

      task =
        mk_task!(uniq("bg-lapse-stale"), scope, %{
          "lifecycle_status" => "researching",
          "engagement" => engagement
        })

      assert %{swept: 0, skipped: 1} =
               with_lost_fence(task.id, fn -> TtlSweeper.sweep_engagement(300) end)

      assert Repo.get!(Document, task.id).content["lifecycle_status"] == "researching"
    end
  end

  # ─── ARM 4 — compactor.ex, the compaction ─────────────────────────────────

  describe "ARM 4 — Compactor.compact/1 (task.compacted)" do
    test "the compaction broadcast carries the STORED updated_at in BOTH fields",
         %{scope: scope} do
      task = mk_done_with_history!(uniq("bg-compact"), scope, 60)
      pre = task.updated_at

      subscribe!()
      assert %{compacted: 1, skipped: 0} = Compactor.compact()

      task_doc_id = task.doc_id

      assert_receive {:document_changed,
                      %{mutation: "task.compacted", doc_id: ^task_doc_id} = msg},
                     2_000

      # This arm ALSO fires the `barkpark_bind_document_revision` AFTER INSERT
      # trigger (the snapshot revision), so the stored row is genuinely written
      # by more than this statement — RETURNING is the only honest receipt.
      assert_broadcast_matches_stored!(msg, task.id, pre)
    end

    test "a lost CAS is still :skipped", %{scope: scope} do
      task = mk_done_with_history!(uniq("bg-compact-stale"), scope, 60)

      assert %{compacted: 0, skipped: 1} =
               with_lost_fence(task.id, fn -> Compactor.compact() end)

      refute Map.has_key?(Repo.get!(Document, task.id).content, "compacted_at")
    end
  end

  # ─── ARM 5 — compactor.ex, the restore ────────────────────────────────────

  describe "ARM 5 — Compactor.restore/2 (task.compaction_restored)" do
    test "the restore broadcast carries the STORED updated_at in BOTH fields", %{scope: scope} do
      task = mk_done_with_history!(uniq("bg-restore"), scope, 60)
      assert %{compacted: 1, skipped: 0} = Compactor.compact()
      snap = snapshot_revision!(task.doc_id)
      pre = Repo.get!(Document, task.id).updated_at

      subscribe!()

      # TRAP: restore/2 takes the document UUID, NOT the doc_id string —
      # cast_uuid folds a doc_id into a silent {:error, :not_found}.
      assert {:ok, _restored} = Compactor.restore(task.id, snap.id)

      task_doc_id = task.doc_id

      assert_receive {:document_changed,
                      %{mutation: "task.compaction_restored", doc_id: ^task_doc_id} = msg},
                     2_000

      assert_broadcast_matches_stored!(msg, task.id, pre)
    end

    test "a lost CAS is still {:error, :stale_claim} — the ONLY error tuple of the five",
         %{scope: scope} do
      task = mk_done_with_history!(uniq("bg-restore-stale"), scope, 60)
      assert %{compacted: 1, skipped: 0} = Compactor.compact()
      snap = snapshot_revision!(task.doc_id)

      assert {:error, :stale_claim} =
               with_lost_fence(task.id, fn -> Compactor.restore(task.id, snap.id) end)

      # Still compacted — a lost fence must not half-restore the row.
      assert is_binary(Repo.get!(Document, task.id).content["compacted_at"])
    end
  end
end
