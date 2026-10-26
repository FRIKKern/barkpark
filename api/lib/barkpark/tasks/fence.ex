defmodule Barkpark.Tasks.Fence do
  @moduledoc false
  # rail-l4 — allow-and-fence. Mutating the WORLD of an `in_progress` task (a
  # blocker edge lands on it, it gets re-parented) must force its holder through
  # a resync WITHOUT ever blocking the mutating agent. The mutator is NEVER
  # rejected; instead the claimed task's `content.claim.epoch` is bumped by 1 in
  # the same transaction, so the holder's next epoch-carrying write (its
  # `close`) is `fenced_off` and it must re-sync (a same-worker re-claim =
  # RENEWAL — see `Barkpark.Tasks.Claim`).
  #
  # This is DELIBERATELY not "reject the mutator": a second agent filing a
  # blocker should never be blocked by whoever happens to hold the dependent.
  # Allow the write, fence the holder.
  #
  # This module owns the EDGE fence (`add_dep/4` and `remove_dep/4`, which
  # `Tasks.add_dep/4` and `Tasks.remove_dep/4` route through). Every edge change
  # also writes a new rev on the dependent and emits `task.mutated`, fenced or
  # not. The MOVE fence is folded into `Tasks.Move`'s reparent
  # CAS write directly (one UPDATE, not a second one).

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      current_epoch: 1,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Tasks.LockKey
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Edges, Internal}

  @event_task_mutated "task.mutated"

  @doc """
  Add a `blocks` (or other) dependency edge `child → parent` AND, when the
  DEPENDENT (`child_uuid`) task is `in_progress`, fence its holder by bumping
  `content.claim.epoch` — all in one transaction. The edge-adder is never
  rejected: a failed fence (CAS lost, no live claim) just adds the edge.

  This is the fencing wrapper `Tasks.add_dep/3` delegates to; it preserves the
  `{:ok, %Edge{}}` / `{:error, %Ecto.Changeset{}}` contract of the bare
  `Edges.add_dep/3` so every existing caller is untouched.

  Endpoints are passed through to `Edges.add_dep/3` in the shape received —
  `%Document{}` structs (twin-canonicalised there) or bare uuids (stored as
  given). The lock and the fence key on the dependent's uuid either way.
  """
  @spec add_dep(Edges.endpoint(), Edges.endpoint(), atom() | String.t(), binary() | nil) ::
          {:ok, Barkpark.Tasks.Edge.t()} | {:error, Ecto.Changeset.t()}
  def add_dep(child, parent, kind \\ :blocks, caller_token_id \\ nil) do
    with_dependent_lock(child, fn child_uuid ->
      case Edges.add_dep(child, parent, kind) do
        {:ok, edge} ->
          {:ok, edge, fence(child_uuid, "edge_added", edge.from_id, edge.to_id, caller_token_id)}

        {:error, %Ecto.Changeset{} = cs} ->
          # A failed INSERT (e.g. FK violation on a ghost id) leaves the
          # transaction aborted — returning the changeset as a plain value
          # would surface as {:error, :rollback} to the caller. Repo.rollback
          # carries it out explicitly, preserving the bare Edges.add_dep
          # contract ({:error, %Ecto.Changeset{}}).
          Repo.rollback(cs)
      end
    end)
  end

  @doc """
  Remove a dependency edge `child → parent` under the same lock and fence as
  `add_dep/4`: removing a blocker changes an `in_progress` holder's world as
  much as adding one does. Returns `{:ok, removed}`; an absent edge removes 0
  rows and fences nobody.
  """
  @spec remove_dep(Edges.endpoint(), Edges.endpoint(), atom() | String.t(), binary() | nil) ::
          {:ok, non_neg_integer()}
  def remove_dep(child, parent, kind \\ :blocks, caller_token_id \\ nil) do
    with_dependent_lock(child, fn child_uuid ->
      {:ok, removed} = Edges.remove_dep(child, parent, kind)

      bundle =
        if removed > 0,
          do:
            fence(child_uuid, "edge_removed", child_uuid, endpoint_uuid(parent), caller_token_id)

      {:ok, removed, bundle}
    end)
  end

  # Advisory lock on the DEPENDENT — the task we may fence. Same key
  # (`LockKey.task/1` = `task:<uuid>`) close/release/stage/sweep use, so the
  # epoch bump serializes with them per-task; edges on OTHER tasks pass through
  # unimpeded. A targeted CLAIM takes this key too, but only AFTER it resolves
  # the slug — its first lock is `task:<doc_id>` and excludes other claims, not
  # this. Broadcasts go out only after commit.
  defp with_dependent_lock(child, fun) do
    child_uuid = endpoint_uuid(child)

    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [LockKey.task(child_uuid)])
        fun.(child_uuid)
      end)

    case result do
      {:ok, {:ok, value, bundle}} ->
        :ok = emit_broadcasts(List.wrap(bundle))
        {:ok, value}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}
    end
  end

  defp fence(child_uuid, what, from_id, to_id, caller_token_id) do
    announce(
      child_uuid,
      what,
      Map.merge(
        %{"edge_change" => what, "edge" => %{"from" => from_id, "to" => to_id}},
        caller_stamp(caller_token_id)
      )
    )
  end

  defp endpoint_uuid(%Document{id: id}), do: id
  defp endpoint_uuid(id) when is_binary(id), do: id

  # Write a new rev on the DEPENDENT and emit one `task.mutated` for it, under
  # the caller's already-held advisory lock + transaction, whatever its status.
  # The rev must move: the GitHub mirror skips a row whose rev it already
  # synced, and the feeds learn of an edge change only through this event. An
  # `in_progress` dependent with a claim lease also gets its `content.claim.epoch`
  # bumped (the fencing kick, payload `fenced`); only the epoch moves — the
  # work_digest, worker, ts_iso, resources stay exactly as the holder stamped
  # them, so its work_digest close-fence still fires only on a real brief edit.
  # Returns a broadcast bundle to emit AFTER commit, or `nil` when the CAS lost.
  defp announce(doc_uuid, what, payload) do
    case Repo.get(Document, doc_uuid) do
      %Document{} = doc ->
        observed_rev = doc.rev
        {new_content, payload} = maybe_fence(doc, what, payload)

        # PDS-D451 — the receipt is the STORED row, not a reconstruction. This
        # arm's receipt never reaches an HTTP caller, but it DOES reach every
        # LiveView/SSE consumer through `Content.Broadcast`, which copies
        # `doc.updated_at` into BOTH the `doc:` map AND `document._updatedAt`
        # (`Envelope.render`) of the same message. A `%{doc | …}` merge omits
        # `updated_at`, so both fields shipped the PREVIOUS write's timestamp.
        case Internal.fenced_content_write(doc, observed_rev, new_content, generate_rev()) do
          {:ok, updated} ->
            ev =
              insert_mutation_event!(updated, @event_task_mutated, observed_rev, "api", payload)

            task_broadcast(updated, @event_task_mutated, ev, observed_rev)

          # NOT an error atom: `nil` is the bundle-absent sentinel this arm has
          # always returned on a lost CAS — `List.wrap(nil) == []` swallows it
          # and `add_dep/3` still returns `{:ok, edge}`.
          :stale ->
            nil
        end

      nil ->
        nil
    end
  end

  defp maybe_fence(
         %Document{content: %{"lifecycle_status" => "in_progress", "claim" => claim} = content} =
           doc,
         what,
         payload
       )
       when is_map(claim) do
    new_claim = Map.put(claim, "epoch", current_epoch(doc) + 1)
    {Map.put(content, "claim", new_claim), Map.put(payload, "fenced", what)}
  end

  defp maybe_fence(%Document{content: content}, _what, payload), do: {content, payload}
end
