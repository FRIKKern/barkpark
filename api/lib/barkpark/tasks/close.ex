defmodule Barkpark.Tasks.Close do
  @moduledoc false
  # Task close + the blocked→open cascade. Extracted from the Barkpark.Tasks
  # facade (which defdelegates close/3 here). Fencing-epoch CAS, the
  # already-terminal guard, and the dependent-unblock walk all live together so
  # the close contract is one cohesive unit.

  import Ecto.Query, only: [from: 2]

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      insert_mutation_event!: 3,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      merge_criteria: 2,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.{Document, Scope}
  alias Barkpark.Repo
  alias Barkpark.Tasks.Edges
  alias Barkpark.Tasks.WorkDigest

  @closed_lifecycle_statuses ~w(done cancelled blocked)
  @event_task_closed "task.closed"
  @event_task_mutated "task.mutated"
  # Advisory cross-task notice (task-obsession layer 4): a task closed with a
  # land digest whose files overlap another in-progress task's claimed scope.
  @event_landed_under_you "task.landed_under_you"

  def close(task_id, worker_id, opts \\ []) when is_binary(worker_id) do
    observed_epoch = Keyword.fetch!(opts, :observed_epoch)
    new_status = Keyword.get(opts, :lifecycle_status, "done")
    observed_rev_opt = Keyword.get(opts, :observed_rev)
    reason = Keyword.get(opts, :reason)
    criteria = Keyword.get(opts, :criteria, [])
    # Land digest (task-obsession layer 3): what this task actually changed —
    # `%{"prs" => [...], "files" => [...], "capability_slugs" => [...]}`. Written
    # to content.landed atomically with the close, so closed tasks become a
    # queryable ledger of touched surfaces (the CI re-land check reads it).
    landed = Keyword.get(opts, :landed)
    # Audit stamp: the api_token id that drove this close (nil for internal
    # callers), threaded into the task.closed mutation_event's document map.
    caller_token_id = Keyword.get(opts, :caller_token_id)

    cond do
      new_status not in @closed_lifecycle_statuses ->
        {:error, {:invalid_lifecycle, new_status}}

      true ->
        do_close_txn(
          task_id,
          worker_id,
          observed_epoch,
          observed_rev_opt,
          new_status,
          reason,
          criteria,
          landed,
          caller_token_id
        )
    end
  end

  defp do_close_txn(
         task_id,
         worker_id,
         observed_epoch,
         observed_rev_opt,
         new_status,
         reason,
         criteria,
         landed,
         caller_token_id
       ) do
    result =
      Repo.transaction(fn ->
        # 1. Advisory lock — per-task. hashtext('task:' || doc_id) gives a
        #    deterministic int4 key; pg_advisory_xact_lock takes an int4 or
        #    bigint and auto-releases at COMMIT/ROLLBACK.
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = observed_rev_opt || doc.rev

            # Already-terminal guard. Under the advisory lock, a serialized
            # 2nd+ caller reads the row AFTER the winner committed → sees
            # `lifecycle_status` already in a terminal state. Without this
            # the default-observed-rev path would let every caller "succeed"
            # in turn (CAS passes against the just-read rev). Treat the
            # already-terminal row as a lost race; the explicit-rev CAS
            # path below still wins/loses on rev when callers pass their
            # own observation.
            cond do
              observed_rev_opt == nil and
                  Map.get(doc.content, "lifecycle_status") in @closed_lifecycle_statuses ->
                {:error, :stale_claim}

              true ->
                with :ok <- check_fencing(doc, observed_epoch),
                     :ok <- check_work_digest(doc, observed_rev_opt),
                     {:ok, updated} <-
                       apply_close_update(
                         doc,
                         worker_id,
                         observed_rev,
                         new_status,
                         reason,
                         criteria,
                         landed
                       ) do
                  ev =
                    insert_mutation_event!(
                      updated,
                      @event_task_closed,
                      observed_rev,
                      "api",
                      caller_stamp(caller_token_id)
                    )

                  unblocked = cascade_unblock_dependents!(updated)
                  landed = notify_landed_under_you!(updated, worker_id)

                  {:ok, updated,
                   [
                     task_broadcast(updated, @event_task_closed, ev, observed_rev)
                     | unblocked ++ landed
                   ]}
                end
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fencing applies only to tasks that carry a claim lease. A task with NO claim
  # record has no lease to fence against, so it closes gracefully (`:ok`) — what
  # lets a never-claimed root/container task close via this same path. A task
  # WITH a claim ALWAYS requires the epoch to match (the dead-worker guard).
  defp check_fencing(%Document{content: content}, observed_epoch) do
    case content do
      %{"claim" => %{"epoch" => row_epoch}} when row_epoch == observed_epoch -> :ok
      %{"claim" => %{"epoch" => _}} -> {:error, :fenced_off}
      # No claim lease — nothing to fence against, close cleanly.
      _ -> :ok
    end
  end

  # "Edited-under-you becomes a 409, never a silent close." When the caller did
  # NOT pin an explicit observed_rev AND the claim carries a work_digest, the
  # doc's current work-defining fields (title/brief/description/acceptance_criteria —
  # for criteria, only each entry's `criterion` TEXT is work-defining; the
  # met/evidence/attempts progress subfields a mid-claim `stamp` writes are
  # excluded by WorkDigest D5, so a worker's own stamps never fence its close)
  # are re-digested inside this close txn and compared to the claim-time stamp.
  # Drift → {:error, {:doc_changed_since_claim, current_rev, changed_fields}} so
  # the worker re-reads the changed brief before closing against stale
  # assumptions. Three deliberate escape hatches keep this narrow:
  #   * an explicit observed_rev bypasses the digest check (the caller opted
  #     into today's strict full-rev CAS instead — see do_close_txn),
  #   * a claim WITHOUT a work_digest (pre-existing/legacy leases) closes
  #     exactly as before (back-compat), and
  #   * self-edits to code_refs/labels/last_worked_at never trip it — those
  #     fields are outside the digest by design (WorkDigest).
  defp check_work_digest(_doc, observed_rev_opt) when observed_rev_opt != nil, do: :ok

  defp check_work_digest(%Document{content: content} = doc, _no_observed_rev) do
    case content do
      %{"claim" => %{"work_digest" => stored} = claim} when is_binary(stored) ->
        field_digests = Map.get(claim, "work_field_digests", %{})
        current = WorkDigest.combined(WorkDigest.field_digests(doc.title, content))

        if current == stored do
          :ok
        else
          changed = WorkDigest.changed_fields(field_digests, doc.title, content)
          {:error, {:doc_changed_since_claim, doc.rev, changed}}
        end

      _ ->
        :ok
    end
  end

  defp apply_close_update(
         %Document{} = doc,
         worker_id,
         observed_rev,
         new_status,
         reason,
         criteria,
         landed
       ) do
    new_rev = generate_rev()
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    # Stamp close metadata into the claim lease when one exists (work-tasks).
    # A never-claimed root/container task has no claim — close it without
    # inventing one; we only flip lifecycle_status.
    new_content =
      case doc.content do
        %{"claim" => claim} when is_map(claim) ->
          updated_claim =
            claim
            |> Map.put("closed_by", worker_id)
            |> Map.put("closed_at", ts_iso)

          doc.content
          |> Map.put("lifecycle_status", new_status)
          |> Map.put("claim", updated_claim)

        _ ->
          Map.put(doc.content, "lifecycle_status", new_status)
      end

    # Dossier close rationale: one scalar write riding the close call. Blank
    # reasons never overwrite an existing value.
    new_content =
      case reason do
        r when is_binary(r) and r != "" -> Map.put(new_content, "close_reason", r)
        _ -> new_content
      end

    # Land digest rides the same close CAS as close_reason. Only a non-empty map
    # writes; a blank/absent digest never clobbers an existing one (a re-close or
    # a CI backfill can add it later without erasing a prior write).
    new_content = merge_landed(new_content, landed)

    # Expectation close-out (living-values §8/§9 — "task proves paper"):
    # acceptance-criteria met/evidence updates ride the SAME rev-CAS write as
    # the lifecycle flip, following the close_reason precedent above. A
    # separate content mutation would race this CAS (close/3 otherwise writes
    # only lifecycle_status/claim/close_reason); folding it into the one
    # UPDATE makes close-and-evidence atomic — both land or neither does.
    # Merge is index-targeted and NEVER rewrites criterion text (the paper's
    # claim citation): only `met` + `evidence` flip. A conflicting update
    # (index out of range, or a `criterion` text guard that no longer
    # matches) aborts the whole close with a CAS-flavoured error so the
    # caller re-reads and retries — deliberate race handling, not silent
    # partial state.
    #
    # Merge-gate auto-stamp (Felix wave-9): the LEAD's merge close synthesizes
    # a met=true update for any acceptance criterion carrying an explicit
    # "merge_gate":true marker so no reviewer hand-patches it. See
    # `autostamp_merge_gate/6` for the conservative guards — it only fires on a
    # terminal `done` close that carries a land digest, and never touches an
    # index the caller already targeted, so a builder's pre-merge close (no
    # landed) is untouched. Runs through the SAME merge_criteria rev-CAS write.
    criteria = autostamp_merge_gate(criteria, doc, worker_id, new_status, landed, ts_iso)

    with {:ok, new_content} <- merge_criteria(new_content, criteria) do
      {rows, _} =
        from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
        |> Repo.update_all(
          set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
        )

      case rows do
        1 -> {:ok, %{doc | content: new_content, rev: new_rev}}
        0 -> {:error, :stale_claim}
      end
    end
  end

  # merge_criteria/2 (the `[%{"index" => i, "met" => bool, "evidence" => str,
  # "criterion" => guard}]` close-out merge) moved to `Tasks.Internal` — ONE
  # definition shared with `Tasks.Stamp`, so mid-claim stamps and close-time
  # flips cannot drift. Imported above.

  # Land digest merge. UNION into any existing digest so a re-close or a CI
  # backfill accumulates rather than clobbers. A nil/empty/malformed payload
  # leaves content untouched (never erases a prior digest).
  @landed_keys ~w(prs files capability_slugs)
  defp merge_landed(content, landed) when is_map(landed) and map_size(landed) > 0 do
    existing =
      case Map.get(content, "landed") do
        m when is_map(m) -> m
        _ -> %{}
      end

    merged =
      Enum.reduce(@landed_keys, existing, fn key, acc ->
        case normalize_landed_list(Map.get(landed, key) || Map.get(landed, safe_atom(key))) do
          [] -> acc
          incoming -> Map.put(acc, key, Enum.uniq((Map.get(acc, key) || []) ++ incoming))
        end
      end)

    if map_size(merged) == 0, do: content, else: Map.put(content, "landed", merged)
  end

  defp merge_landed(content, _), do: content

  # Merge-gate auto-stamp (Felix wave-9). Kills the recurring ledger toil where
  # the final "PR merged"/LEAD-CLOSED acceptance criterion is left met=false at
  # builder-close time and a reviewer hand-patches it every wave. When the LEAD
  # closes on merge, synthesize a met=true criteria update for any criterion the
  # AUTHOR explicitly marked with `"merge_gate" => true`.
  #
  # CONSERVATIVE by design — the union of ALL these must hold or nothing is
  # stamped (a builder's honest pre-merge close is never touched):
  #   * new_status is the terminal `done` (a cancelled/blocked close is not a merge),
  #   * a non-empty `landed` digest rides the close (the LEAD merge close carries
  #     one; a builder pre-merge close does not — this is what prevents recreating
  #     the Mode-A false-true bug),
  #   * the criterion carries the EXPLICIT `"merge_gate" => true` marker — never a
  #     text / last-entry / index heuristic (only 14/34 Felix children carry the
  #     'MERGE GATE' text convention, so a heuristic would both miss and misfire),
  #   * it is still `met` != true (idempotent — an already-stamped gate is left alone),
  #   * the caller's `criteria` payload did NOT already target that index (an
  #     explicit caller update always wins; we never overwrite it).
  # The synthetic update rides the SAME merge_criteria + rev-CAS write as every
  # other close-time criteria flip, so it lands atomically with the close or not
  # at all.
  defp autostamp_merge_gate(criteria, %Document{} = doc, worker_id, "done", landed, ts_iso)
       when is_map(landed) and map_size(landed) > 0 and is_list(criteria) do
    targeted = MapSet.new(criteria, &Map.get(&1, "index"))

    evidence = compose_merge_gate_evidence(doc, worker_id, landed, ts_iso)

    synthetic =
      doc.content
      |> merge_gate_criteria_list()
      |> Enum.with_index()
      |> Enum.filter(fn {entry, i} ->
        is_map(entry) and Map.get(entry, "merge_gate") == true and
          Map.get(entry, "met") != true and not MapSet.member?(targeted, i)
      end)
      |> Enum.map(fn {_entry, i} -> %{"index" => i, "met" => true, "evidence" => evidence} end)

    criteria ++ synthetic
  end

  defp autostamp_merge_gate(criteria, _doc, _worker, _status, _landed, _ts_iso), do: criteria

  defp merge_gate_criteria_list(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  # "auto: lead-closed on merge by <worker> (epoch <n>) — landed <what> at <ts>".
  # The claim epoch is read from the doc's own claim lease (nil for an unclaimed
  # container close → rendered "?"); the landed summary prefers PR numbers, then a
  # commit sha, then file paths, so the evidence names a concrete merge artifact.
  defp compose_merge_gate_evidence(%Document{content: content}, worker_id, landed, ts_iso) do
    epoch =
      case get_in(content, ["claim", "epoch"]) do
        nil -> "?"
        e -> to_string(e)
      end

    "auto: lead-closed on merge by #{worker_id} (epoch #{epoch}) — landed #{landed_summary(landed)} at #{ts_iso}"
  end

  defp landed_summary(landed) do
    prs = normalize_landed_list(Map.get(landed, "prs") || Map.get(landed, safe_atom("prs")))
    commit = Map.get(landed, "commit") || Map.get(landed, "commits")
    files = normalize_landed_list(Map.get(landed, "files") || Map.get(landed, safe_atom("files")))

    cond do
      prs != [] -> "PR " <> Enum.map_join(prs, ", ", &"##{&1}")
      is_binary(commit) and commit != "" -> "commit #{commit}"
      files != [] -> Enum.join(files, ", ")
      true -> "merge"
    end
  end

  defp normalize_landed_list(nil), do: []
  defp normalize_landed_list(list) when is_list(list), do: Enum.reject(list, &is_nil/1)
  defp normalize_landed_list(scalar), do: [scalar]

  defp safe_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> :__missing__
  end

  # After a task flips to `done`, walk every inbound `blocks` edge and flip the
  # dependent's lifecycle_status "blocked"→"open" IFF every one of ITS blockers
  # is now `done`. Same advisory-lock-guarded transaction so two concurrent
  # closes can't double-flip the same dependent. Returns one broadcast bundle
  # per flipped dependent for the caller to announce after commit.
  defp cascade_unblock_dependents!(%Document{content: %{"lifecycle_status" => "done"}} = parent) do
    parent
    |> Map.fetch!(:id)
    |> Edges.dependents(kind: :blocks)
    |> Enum.flat_map(fn %Document{} = dep ->
      if all_blockers_done?(dep) and Map.get(dep.content, "lifecycle_status") == "blocked" do
        new_rev = generate_rev()
        new_content = Map.put(dep.content, "lifecycle_status", "open")

        {1, _} =
          from(d in Document, where: d.id == ^dep.id and d.rev == ^dep.rev)
          |> Repo.update_all(
            set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
          )

        unblocked = %{dep | content: new_content, rev: new_rev}
        ev = insert_mutation_event!(unblocked, @event_task_mutated, dep.rev)
        [task_broadcast(unblocked, @event_task_mutated, ev, dep.rev)]
      else
        []
      end
    end)
  end

  defp cascade_unblock_dependents!(_non_done_parent), do: []

  # Land-under-you notice (task-obsession layer 4, the genuinely-new half — the
  # rest of "scope overlap" is already the claim.resources / resource_conflict
  # machinery). When a task closes carrying a land digest, any IN-PROGRESS task
  # whose claimed scope (content.claim.resources) intersects the landed files
  # gets a `task.landed_under_you` mutation event so its worker knows to rebase.
  #
  # PURE NOTIFICATION — never mutates the affected task; it rides the existing
  # mutation-event/broadcast channel (same as the unblock cascade). ADVISORY —
  # emitted after the close has already committed. Tenant-scoped and fail-closed:
  # an unscoped closer (nil workspace) emits nothing rather than blasting every
  # tenant.
  defp notify_landed_under_you!(%Document{content: content} = closed, by_worker) do
    files =
      content
      |> get_in(["landed", "files"])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    ws = Map.get(closed, :workspace_id)

    if files == [] or is_nil(ws) do
      []
    else
      do_notify_landed(closed, files, ws, by_worker)
    end
  end

  defp do_notify_landed(%Document{} = closed, files, ws, by_worker) do
    project_id = Map.get(closed, :project_id)

    from(d in Document,
      where: d.type == "task",
      where: fragment("?->>'kind'", d.content) == "task",
      where: fragment("?->>'lifecycle_status'", d.content) == "in_progress",
      # SQL-side overlap: the claim holds at least one of the landed files.
      where: fragment("jsonb_exists_any(?->'claim'->'resources', ?)", d.content, ^files),
      where: d.id != ^closed.id,
      where: d.dataset == ^closed.dataset
    )
    |> Scope.scope_to_workspace(ws, project_id)
    |> Repo.all()
    |> Enum.map(fn %Document{} = affected ->
      meta = %{
        "landed_under_you" => %{
          "landed_task" => closed.doc_id,
          "files" => resource_overlap(affected, files),
          "by_worker" => by_worker
        }
      }

      ev =
        insert_mutation_event!(affected, @event_landed_under_you, affected.rev, "api", meta)

      task_broadcast(affected, @event_landed_under_you, ev, affected.rev)
    end)
  end

  defp resource_overlap(%Document{content: content}, files) do
    held =
      content
      |> get_in(["claim", "resources"])
      |> List.wrap()

    Enum.filter(files, &(&1 in held))
  end

  defp all_blockers_done?(%Document{} = dep) do
    dep.id
    |> Edges.dependencies(kind: :blocks)
    |> Enum.all?(fn %Document{content: c} ->
      Map.get(c, "lifecycle_status") == "done"
    end)
  end
end
