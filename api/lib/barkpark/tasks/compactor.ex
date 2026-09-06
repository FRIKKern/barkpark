defmodule Barkpark.Tasks.Compactor do
  @moduledoc """
  W7a step 6 — Oban worker that bounds per-task storage growth on
  terminal-state task documents.

  ## The storage-bound guarantee

  W7a's task substrate stores tasks as `documents` rows whose `content`
  JSON can grow over a task's lifetime. Without a compactor, a long-lived
  `done` task can carry a large `content` payload that bloats every
  dataset read and every revision write. This worker enforces the
  contract: **live `content` stays small; the full pre-compaction payload
  is durably preserved (reversibly) in the `revisions` table.**

  ## A note on `content.history` — forward-looking, NOT yet wired

  This worker was designed against an envisioned `content.history` event
  log appended on every claim/close/heartbeat/comment. **That writer does
  not exist in the shipped code.** The canonical task mutation log lives
  in the separate `mutation_events` table — `Tasks.claim/2`, `close/3`,
  `relabel_by_id/3`, and `TtlSweeper` all emit there, NOT to
  `content.history` (grep `history` in `tasks.ex` = 0 hits). Consequently
  the history-length eligibility branch in `eligible_query/1`
  (the `jsonb_array_length(...->'history') > N` arm) is **latent**: on
  real rows `content.history` is absent, so that arm never fires and is
  exercised only by `CompactorTest`, which fabricates a `content.history`
  array. The **active** eligibility path in production is the byte-size
  arm (`pg_column_size(content) > S`). The history-length arm is kept as
  the wiring point for if/when a lifecycle history writer lands.

  ## Three phases, one Oban job per cycle

    1. **Analyze** — `eligible_query/1` selects task documents that are
       terminal-lifecycle (`done` / `cancelled` by default; configurable
       so the next escalation — compact `open` rows with huge history —
       is one config flip away), have NOT yet been compacted
       (`content.compacted_at IS NULL` is the idempotence flag), and
       carry either a tall history array (default N=50 entries) or a
       large content payload (default S=65_536 bytes). Capped at
       `:cap` rows/cycle (default 100) to bound the Oban job duration.

    2. **Snapshot in `revisions` (reversible)** — BEFORE the live
       content update, insert a SPECIAL revision row carrying the full
       pre-compaction `content` payload with
       `action = "compaction_snapshot"`. The action column is the
       existing free-string discriminator the revision-restore path
       already understands; using it means the snapshot is findable via
       the normal `Content.list_revisions/4` surface
       (`Enum.filter(&(&1.action == "compaction_snapshot"))`) and
       restorable via `restore/2` below. The inserted revision's id is
       captured + threaded into the summary `note` so an operator
       reading the live content sees exactly which revision row holds
       the pre-compaction state.

    3. **Summary in `content`** — for each selected doc:

         * `content.history_summary` = derived stats
           (`event_count`, `first_ts`, `last_ts`, `status_transitions`,
           `worker_count`, `distinct_workers`,
           `note: "compacted from N events; full history in revision <rev_id>"`)
         * `content.history` is REPLACED with the last 3 entries
           (a small tail keeps the rail / debug UIs useful at zero
           extra cost; the full pre-compaction array lives in the
           snapshot revision; choice is defended in the test that
           proves byte-for-byte reversibility via `restore/2`).
         * `content.compacted_at` is stamped with `now_iso8601` — the
           idempotence flag the next cycle's `eligible_query/1`
           excludes on.
         * The update is CAS-guarded on `documents.rev` (matches the
           W7-04 mutation pattern). On CAS failure: skip; next cycle
           picks it up if still eligible.

  ## Per-task advisory lock — the SAME key as `Tasks.close/3` + `TtlSweeper`

  `pg_advisory_xact_lock(hashtext('task:' || uuid))` —
  `Barkpark.Tasks.LockKey.task/1` on the candidate's UUID PRIMARY KEY,
  identical to `Tasks.close/3` and `Barkpark.Tasks.TtlSweeper`. (The
  candidate query selects `%Document{id: …}`; the value was once bound to
  a parameter named `doc_id`, which read as the SLUG family.) This means a
  compaction NEVER interleaves with a late claim/close/sweep on the
  same task; the three lifecycle writers serialize per-task without
  contending on row locks. Closes on DIFFERENT tasks pass through
  unimpeded.

  ## Reversibility — `restore/2`

  `restore/2` takes a `doc_id` (binary uuid) + `snapshot_revision_id`
  and atomically swaps the live `content` back to the snapshot's
  payload, clearing `content.compacted_at` and `content.history_summary`
  in the process. Emits a `task.compaction_restored` mutation_event with
  the snapshot revision id. **Without `restore/2` the snapshot is just
  dead bytes** — this function is the reversibility proof. The
  CompactorTest's restore case captures pre-compaction content,
  compacts, restores, then asserts byte-for-byte equality of
  `content.history`.

  ## Oban wiring (see config/config.exs)

    * Queue `tasks_compact`, concurrency=1 (defense in depth on top of
      the per-task advisory lock).
    * Cron `"0 */6 * * *"` — every 6 hours. Way coarser than TTL's
      per-minute cadence; compaction is batch, not real-time.

  ## Config

    * `:task_compaction_min_history` — N for the history-length
      eligibility threshold. Default 50.
    * `:task_compaction_min_bytes` — S for the content-size eligibility
      threshold (rough `pg_column_size(content)`). Default 65_536.
    * `:task_compaction_cap` — max rows per cycle. Default 100.
    * `:task_compaction_lifecycle_statuses` — list of terminal-status
      strings to consider. Default `["done", "cancelled"]`.
    * `:task_compaction_worklog_tail` — keep this many `content.worklog`
      entries on compaction (the dossier handoff journal; a synthetic
      rollup entry notes the truncation + snapshot revision). Default 5.
    * `:task_compaction_history_tail` — keep this many entries on the
      live content after compaction. Default 3.
  """

  use Oban.Worker, queue: :tasks_compact, max_attempts: 3

  import Ecto.Query

  alias Barkpark.Tasks.LockKey
  alias Barkpark.Content.{Document, MutationEvent, Revision}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Internal

  @event_task_compacted "task.compacted"
  @event_task_compaction_restored "task.compaction_restored"

  @snapshot_action "compaction_snapshot"

  @default_min_history 50
  @default_min_bytes 65_536
  @default_cap 100
  @default_lifecycle_statuses ~w(done cancelled)
  @default_history_tail 3
  @default_worklog_tail 5

  @doc "The mutation_events kinds this worker emits."
  @spec event_kinds() :: %{compacted: String.t(), restored: String.t()}
  def event_kinds do
    %{compacted: @event_task_compacted, restored: @event_task_compaction_restored}
  end

  @doc "The `revisions.action` string the snapshot rows carry."
  @spec snapshot_action() :: String.t()
  def snapshot_action, do: @snapshot_action

  @impl Oban.Worker
  def perform(%Oban.Job{} = _job) do
    {:ok, compact()}
  end

  @doc """
  Pure entry point — bypasses Oban.Job wrapping for tests. Returns
  `%{compacted: N, skipped: M}` (matches TtlSweeper's `%{swept, skipped}`
  shape).

  Accepts the same config opts as the application env values for
  per-call override (used by the test suite).
  """
  @spec compact(keyword()) :: %{compacted: non_neg_integer(), skipped: non_neg_integer()}
  def compact(opts \\ []) do
    cfg = resolve_config(opts)
    candidates = eligible_query(cfg) |> Repo.all()

    Enum.reduce(candidates, %{compacted: 0, skipped: 0}, fn %Document{id: task_uuid}, acc ->
      case compact_one(task_uuid, cfg) do
        :compacted -> %{acc | compacted: acc.compacted + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  # ─── Analyze: eligible_query/1 ────────────────────────────────────────────

  @doc """
  The eligibility query — exposed so tests can assert selection
  semantics without driving the full compaction loop.

  Returns an Ecto query (NOT executed) of `%Document{}` rows that are
  candidates for the current cycle. Apply `Repo.all/1` to materialize.
  """
  @spec eligible_query(keyword() | map()) :: Ecto.Query.t()
  def eligible_query(opts \\ []) do
    cfg = resolve_config(opts)

    min_history = cfg.min_history
    min_bytes = cfg.min_bytes
    cap = cfg.cap
    statuses = cfg.lifecycle_statuses

    from(d in Document,
      where: d.type == "task",
      where: fragment("?->>'kind'", d.content) == "task",
      where: fragment("?->>'lifecycle_status'", d.content) in ^statuses,
      where: fragment("?->>'compacted_at'", d.content) |> is_nil(),
      where:
        fragment(
          "(COALESCE(jsonb_array_length(CASE WHEN jsonb_typeof(?->'history') = 'array' THEN ?->'history' ELSE '[]'::jsonb END), 0) > ?) OR (pg_column_size(?) > ?)",
          d.content,
          d.content,
          ^min_history,
          d.content,
          ^min_bytes
        ),
      order_by: [asc: d.inserted_at],
      limit: ^cap
    )
  end

  # ─── Compaction (the per-task locked unit) ────────────────────────────────

  defp compact_one(task_uuid, cfg) do
    result =
      Repo.transaction(fn ->
        # Per-task advisory lock — SAME key as Tasks.close/3 and TtlSweeper.
        # A concurrent close on the same task waits here; a concurrent
        # sweep on the same task waits here; compactions on DIFFERENT
        # tasks pass through unimpeded.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_uuid)])

        # global-read: in-lock by-PK re-read of a candidate the compactor's own cross-tenant eligibility scan selected — internal Oban worker, tenancy resolved by eligible_query/1, same posture as TtlSweeper's reap re-read.
        case Repo.get(Document, task_uuid) do
          nil ->
            :skipped

          %Document{} = doc ->
            cond do
              not still_eligible?(doc, cfg) ->
                # Another caller (a close from `open`→`done`, an earlier
                # compaction in this same run, a manual edit) changed
                # the row out from under us. Skip — next cycle picks it
                # up if still eligible.
                :skipped

              true ->
                apply_compaction(doc, cfg)
            end
        end
      end)

    case result do
      {:ok, {:compacted, doc, event_id, previous_rev}} ->
        # Post-commit PubSub — same canonical topics/shape every document
        # write broadcasts (SSE listen endpoint + StudioLive parity).
        Barkpark.Content.broadcast_document_mutation(doc, @event_task_compacted,
          event_id: event_id,
          previous_rev: previous_rev
        )

        :compacted

      {:ok, outcome} ->
        outcome

      {:error, _} ->
        :skipped
    end
  end

  # Recheck under the lock — the outer SELECT was advisory. The row
  # must STILL be in a terminal status AND STILL not have compacted_at
  # set AND STILL meet a size/length threshold.
  defp still_eligible?(%Document{content: content}, cfg) do
    Map.get(content, "lifecycle_status") in cfg.lifecycle_statuses and
      is_nil(Map.get(content, "compacted_at"))
  end

  defp apply_compaction(%Document{} = doc, cfg) do
    observed_rev = doc.rev

    # ── Phase 2: insert reversible snapshot revision FIRST. We need its
    #            id to thread into the summary's `note`.
    snapshot =
      %Revision{}
      |> Revision.changeset(%{
        doc_id: doc.doc_id,
        type: doc.type,
        dataset: doc.dataset,
        dataset_id: doc.dataset_id,
        title: doc.title,
        status: doc.status,
        content: doc.content,
        action: @snapshot_action,
        workspace_id: doc.workspace_id,
        project_id: doc.project_id
      })
      |> Repo.insert!()

    # ── Phase 3: build the summary + tail + compacted_at flag.
    history = list_history(doc.content)
    summary = build_summary(history, snapshot.id)
    tail = Enum.take(history, -cfg.history_tail)
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    new_rev = generate_rev()

    new_content =
      doc.content
      |> Map.put("history", tail)
      |> Map.put("history_summary", summary)
      |> tail_worklog(cfg, ts_iso, snapshot.id)
      |> Map.put("compacted_at", ts_iso)
      |> Map.put("compaction_snapshot_revision_id", snapshot.id)

    # PDS-D451 — the receipt is the STORED row. `compact_one/2` broadcasts
    # `updated`, and `Content.Broadcast` copies `doc.updated_at` into BOTH
    # `doc.updated_at` AND `document._updatedAt` of that one message. This arm
    # ALSO fires the `barkpark_bind_document_revision` AFTER INSERT trigger on
    # the snapshot revision, so `RETURNING` is the only way the receipt carries
    # what Postgres actually holds.
    case Internal.fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev =
          insert_compacted_event!(
            updated,
            observed_rev,
            length(history),
            snapshot.id
          )

        # Bundle for the post-commit broadcast in compact_one/2.
        {:compacted, updated, ev.id, observed_rev}

      :stale ->
        # CAS failed under the lock — extremely rare (we held it through
        # the read + write), but covered. The snapshot row remains, with
        # no live content pointing at it; the next compaction cycle will
        # see the row is still eligible (compacted_at still NULL) and
        # produce a fresh snapshot. The stale snapshot is reachable via
        # list_revisions and harmless — at worst a little extra storage
        # the existing revision-pruning sweep handles.
        :skipped
    end
  end

  # The history array is the growing event log. Defensive: if a doc has
  # no history field, treat as empty list.
  defp list_history(content) do
    case Map.get(content, "history") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Tail the dossier worklog (tsk-dossier-worklog-compaction). The handoff
  # journal is agent-written and uncapped, so a closed task's worklog was
  # the one content key compaction could not shrink — a >64KB row burned a
  # snapshot-only cycle. The FULL worklog is already inside the snapshot
  # revision (taken from doc.content before this transform), so restore/2
  # brings every entry back. The rollup is a SYNTHETIC worklog entry, not
  # a side-channel key: the next claiming agent reading handoff context
  # sees the truncation note exactly where it reads everything else. A
  # worklog at/under the tail (or absent) is left byte-identical.
  defp tail_worklog(content, cfg, ts_iso, snapshot_revision_id) do
    case Map.get(content, "worklog") do
      worklog when is_list(worklog) and length(worklog) > 0 ->
        if length(worklog) > cfg.worklog_tail do
          rollup = %{
            "ts" => ts_iso,
            "worker" => "compactor",
            "kind" => "progress",
            "note" =>
              "compacted from #{length(worklog)} worklog entries; " <>
                "full worklog in revision #{snapshot_revision_id}"
          }

          Map.put(content, "worklog", [rollup | Enum.take(worklog, -cfg.worklog_tail)])
        else
          content
        end

      _ ->
        content
    end
  end

  # Derived summary stats. Per the W7-06 brief — event_count, first/last
  # ts, status transitions, worker count + distinct workers, note that
  # carries the snapshot revision id.
  defp build_summary(history, snapshot_revision_id) do
    transitions = extract_transitions(history)
    workers = extract_workers(history)

    %{
      "event_count" => length(history),
      "first_ts" => first_ts(history),
      "last_ts" => last_ts(history),
      "status_transitions" => transitions,
      "worker_count" => length(workers),
      "distinct_workers" => workers,
      "note" =>
        "compacted from #{length(history)} events; full history in revision #{snapshot_revision_id}"
    }
  end

  defp first_ts([]), do: nil
  defp first_ts([first | _]), do: Map.get(first, "ts") || Map.get(first, "ts_iso")

  defp last_ts([]), do: nil

  defp last_ts(history) do
    last = List.last(history)
    Map.get(last, "ts") || Map.get(last, "ts_iso")
  end

  defp extract_transitions(history) do
    history
    |> Enum.flat_map(fn entry ->
      case Map.get(entry, "kind") do
        "status_change" ->
          [
            %{
              "from" => Map.get(entry, "from"),
              "to" => Map.get(entry, "to"),
              "ts" => Map.get(entry, "ts") || Map.get(entry, "ts_iso")
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp extract_workers(history) do
    history
    |> Enum.map(&Map.get(&1, "worker"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # ─── Restore: reversibility proof ─────────────────────────────────────────

  @doc """
  Atomically swap a task's live `content` back to a `compaction_snapshot`
  revision's payload, clearing `content.compacted_at` /
  `content.history_summary` / `content.compaction_snapshot_revision_id`
  in the process.

  ## Arguments
    * `doc_id` — `documents.id` (uuid) of the task to restore.
    * `snapshot_revision_id` — `revisions.id` (uuid) of the snapshot row.
      Must have `action = "compaction_snapshot"` and belong to the same
      `doc_id` (`revisions.doc_id == documents.doc_id`).

  ## Returns
    * `{:ok, %Document{}}` — restored; the returned doc carries the
      restored `content` and a bumped `rev`. A `task.compaction_restored`
      mutation_event is written in the same transaction.
    * `{:error, :not_found}` — no such document.
    * `{:error, :revision_not_found}` — no such revision.
    * `{:error, :not_a_compaction_snapshot}` — the revision is not a
      compaction_snapshot (wrong action), or its doc_id does not match.
    * `{:error, :stale_claim}` — CAS failed under the lock (rare).

  Per-task protected by the SAME `pg_advisory_xact_lock` key
  (`LockKey.task/1`, on the uuid) as `Tasks.close/3` / `TtlSweeper` /
  `compact_one/2`, so a restore never interleaves with a concurrent
  close, sweep, or compaction on the same task. A targeted CLAIM also
  takes that key, but only after it has resolved the slug to a uuid — its
  first, pre-resolution lock is `task:<doc_id>` and excludes claims
  only.
  """
  @spec restore(binary(), binary()) ::
          {:ok, Document.t()}
          | {:error, :not_found | :revision_not_found | :not_a_compaction_snapshot | :stale_claim}
  def restore(doc_id, snapshot_revision_id)
      when is_binary(doc_id) and is_binary(snapshot_revision_id) do
    # Guard the :binary_id casts — a raw non-UUID id (e.g. from a future
    # restore endpoint's path/body params) would otherwise raise
    # Ecto.Query.CastError -> 500 inside Repo.get/2. A malformed id can't
    # identify any row, so fold it into the existing not_found branches
    # (mirrors Barkpark.Sharing.Links.revoke/1).
    with {:ok, uuid} <- cast_uuid(doc_id, :not_found),
         {:ok, rev_uuid} <- cast_uuid(snapshot_revision_id, :revision_not_found) do
      do_restore(uuid, rev_uuid)
    end
  end

  defp cast_uuid(id, error_reason) do
    case Repo.uuid_or_nil(id) do
      nil -> {:error, error_reason}
      uuid -> {:ok, uuid}
    end
  end

  defp do_restore(task_uuid, snapshot_revision_id) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(task_uuid)])

        # global-read: in-lock by-PK read of the uuid restore/2 cast — an internal maintenance path with no workspace_id thread, the same posture as compact_one/2 above.
        with %Document{} = doc <- Repo.get(Document, task_uuid) || {:error, :not_found},
             %Revision{} = rev <-
               Repo.get(Revision, snapshot_revision_id) || {:error, :revision_not_found},
             :ok <- check_snapshot(rev, doc) do
          apply_restore(doc, rev)
        else
          {:error, reason} -> {:error, reason}
        end
      end)

    case result do
      {:ok, {:ok, doc, event_id, previous_rev}} ->
        # Post-commit PubSub — restore mutates the live row exactly like the
        # other task lifecycle writers, so it announces the same way.
        Barkpark.Content.broadcast_document_mutation(doc, @event_task_compaction_restored,
          event_id: event_id,
          previous_rev: previous_rev
        )

        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_snapshot(%Revision{action: @snapshot_action, doc_id: rev_doc_id}, %Document{
         doc_id: doc_doc_id
       }) do
    if rev_doc_id == doc_doc_id do
      :ok
    else
      {:error, :not_a_compaction_snapshot}
    end
  end

  defp check_snapshot(_rev, _doc), do: {:error, :not_a_compaction_snapshot}

  defp apply_restore(%Document{} = doc, %Revision{} = rev) do
    observed_rev = doc.rev
    new_rev = generate_rev()

    # The snapshot's content IS the pre-compaction payload. Restoring
    # means making it the live content again, minus the compaction
    # markers (which apply_compaction added on top of the snapshot's
    # state — we strip them to leave the row as if no compaction had
    # ever happened).
    new_content =
      rev.content
      |> Map.delete("compacted_at")
      |> Map.delete("history_summary")
      |> Map.delete("compaction_snapshot_revision_id")

    # PDS-D451 — the receipt is the STORED row: `restore/2` both RETURNS this
    # doc and broadcasts it, so a reconstruction leaked the pre-write timestamp
    # in `doc.updated_at`, `document._updatedAt` and the returned struct alike.
    case Internal.fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev = insert_restored_event!(updated, observed_rev, rev.id)
        {:ok, updated, ev.id, observed_rev}

      :stale ->
        {:error, :stale_claim}
    end
  end

  # ─── Event emission ───────────────────────────────────────────────────────

  defp insert_compacted_event!(
         %Document{} = doc,
         previous_rev,
         event_count_compacted,
         snapshot_revision_id
       ) do
    payload = %{
      "previous_rev" => previous_rev,
      "rev" => doc.rev,
      "event_count_compacted" => event_count_compacted,
      "snapshot_revision_id" => snapshot_revision_id
    }

    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: doc.dataset,
      type: doc.type,
      doc_id: doc.doc_id,
      mutation: @event_task_compacted,
      rev: doc.rev,
      previous_rev: previous_rev,
      document: %{
        "doc_id" => doc.doc_id,
        "type" => doc.type,
        "title" => doc.title,
        "status" => doc.status,
        "content" => doc.content,
        "rev" => doc.rev,
        "compacted" => payload
      },
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp insert_restored_event!(%Document{} = doc, previous_rev, snapshot_revision_id) do
    payload = %{
      "previous_rev" => previous_rev,
      "rev" => doc.rev,
      "snapshot_revision_id" => snapshot_revision_id
    }

    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: doc.dataset,
      type: doc.type,
      doc_id: doc.doc_id,
      mutation: @event_task_compaction_restored,
      rev: doc.rev,
      previous_rev: previous_rev,
      document: %{
        "doc_id" => doc.doc_id,
        "type" => doc.type,
        "title" => doc.title,
        "status" => doc.status,
        "content" => doc.content,
        "rev" => doc.rev,
        "compaction_restored" => payload
      },
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # ─── Config + helpers ─────────────────────────────────────────────────────

  defp resolve_config(opts) do
    cfg = if is_list(opts), do: Enum.into(opts, %{}), else: opts

    %{
      min_history:
        Map.get(
          cfg,
          :min_history,
          Application.get_env(:barkpark, :task_compaction_min_history, @default_min_history)
        ),
      min_bytes:
        Map.get(
          cfg,
          :min_bytes,
          Application.get_env(:barkpark, :task_compaction_min_bytes, @default_min_bytes)
        ),
      cap:
        Map.get(
          cfg,
          :cap,
          Application.get_env(:barkpark, :task_compaction_cap, @default_cap)
        ),
      lifecycle_statuses:
        Map.get(
          cfg,
          :lifecycle_statuses,
          Application.get_env(
            :barkpark,
            :task_compaction_lifecycle_statuses,
            @default_lifecycle_statuses
          )
        ),
      history_tail:
        Map.get(
          cfg,
          :history_tail,
          Application.get_env(:barkpark, :task_compaction_history_tail, @default_history_tail)
        ),
      worklog_tail:
        Map.get(
          cfg,
          :worklog_tail,
          Application.get_env(:barkpark, :task_compaction_worklog_tail, @default_worklog_tail)
        )
    }
  end

  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
