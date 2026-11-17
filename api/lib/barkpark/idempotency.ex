defmodule Barkpark.Idempotency do
  @moduledoc """
  Idempotency-Key dedup store. Backs P1-k (mutation dedup) and P1-d
  (webhook delivery dedup). Postgres-only; rows expire after `ttl_seconds`
  and are removed by `sweep/1`.

  ## Claim-first concurrency guarantee

  Dedup is CLAIM-FIRST: `claim/2` reserves the `key_hash` row via
  `INSERT ... ON CONFLICT DO NOTHING` BEFORE the handler runs, so two in-flight
  requests carrying the same key can never both execute a non-idempotent
  mutation. Exactly one wins the insert (`:claimed`); the loser gets
  `{:replay, cached}` if the winner already completed, or `:in_progress`
  (→ 409) while the winner is still executing. The completed response is
  written by `complete/5` from `register_before_send`; a 5xx or crashed request
  is released by `release/1` so a retry can re-claim.

  Because the pending row is the anchor — inserted independently of, and before,
  the body store — a failed `complete/5` cannot silently disable dedup: the
  reservation still blocks concurrent duplicates. A store failure is surfaced to
  telemetry (`[:barkpark, :idempotency, :store_error]`), never swallowed.

  ## Crash / stale-pending reclaim

  A reservation whose request dies before `complete/5`/`release/1` runs would
  otherwise wedge the key until the 24h sweep. `claim/2` reclaims a pending row
  older than `pending_ttl_seconds` (default 60s — comfortably longer than any
  real mutation, short enough to recover a crashed one) via an atomic
  `UPDATE ... WHERE state='pending' AND inserted_at < cutoff`, so a dead
  reservation is retryable.

  ## A write that committed and then answered a fault

  A 5xx releases the claim so the retry runs, because most 5xx come before
  any write. But a write can COMMIT and still answer a fault: a connection
  lost at commit (503), or a raise after the transaction returned (500).
  Releasing then lets the retry run the write a second time
  (task-717c91a6e9b6758b). So the plug HOLDS its claimed hash in the request
  process (`hold/1`), and the mutate batch calls `mark_committed/0` as the
  last statement inside its own transaction: the row becomes `"committed"`
  if and only if the write committed. `release/1` deletes only `"pending"`
  rows, so a committed row survives the 5xx, which is then recorded and
  replayed (`settle_fault/5`). A committed row with no recorded answer (the
  process died before before_send) is never reclaimed: it answers
  `:in_progress` until it is swept.

  Limits, by design:

    * The held key lives in the request process's dictionary. A write run in
      ANOTHER process (a Task, a GenServer call) does not see it,
      `mark_committed/0` is a no-op there, and a 5xx after that write
      releases the key as before.
    * Only the mutate batch marks today. The other doors behind the plug
      (document and field ops, disconnect, the chat send) release on 5xx as
      before.
    * Dry runs and batches that roll back never mark: the mark is skipped
      for a dry run and rolls back with any refused batch.
    * The held key belongs to one request. Bandit serves a keep-alive
      connection's requests in one process, so the endpoint forgets it when a
      request starts and the plug forgets it in before_send.
  """

  import Ecto.Query
  require Logger
  alias Barkpark.Repo
  alias Barkpark.Repo.IdempotencyStore
  alias Barkpark.Repo.IdempotencyStore.Key

  @default_ttl_seconds 86_400
  @default_pending_ttl_seconds 60
  # Upper bound on rows one `sweep_batch/1` statement removes.
  @default_sweep_batch_limit 5_000

  @held_key :barkpark_idempotency_held_key

  @doc "Hold `hash` for this request process: the claim a write here may mark committed."
  @spec hold(String.t()) :: :ok
  def hold(hash) when is_binary(hash) do
    Process.put(@held_key, hash)
    :ok
  end

  @doc "Forget the held key. Run at every request start and in the plug's before_send."
  @spec forget_held_key() :: :ok
  def forget_held_key do
    Process.delete(@held_key)
    :ok
  end

  @doc false
  def held_key, do: Process.get(@held_key)

  @doc """
  Mark the held key's pending row `"committed"`. Call it as the LAST statement
  inside the write's own transaction, so the mark commits or rolls back with
  the write. `:none` when this process holds no key (no Idempotency-Key, or a
  write running in another process) or the row is not pending.
  """
  @spec mark_committed() :: :marked | :none
  def mark_committed do
    case Process.get(@held_key) do
      nil ->
        :none

      hash ->
        query = from(k in Key, where: k.key_hash == ^hash and k.state == "pending")

        case Repo.update_all(query, set: [state: "committed"]) do
          {1, _} ->
            :telemetry.execute([:barkpark, :idempotency, :marked_committed], %{count: 1}, %{
              key_hash: hash
            })

            :marked

          {_, _} ->
            :none
        end
    end
  end

  @doc """
  Settle a claim whose request answered 5xx (or nothing): a committed row
  records that answer, to be replayed; a pending row is released, so the retry
  runs. Returns `:recorded` when a committed row took the answer, else
  `:released`. With no answer (`status` nil) a committed row is left as it
  is: never released, never reclaimed.
  """
  def settle_fault(hash, scope, status, body, headers) do
    committed = from(k in Key, where: k.key_hash == ^hash and k.state == "committed")

    recorded =
      if is_integer(status) do
        Repo.update_all(committed,
          set: [
            state: "completed",
            scope: scope,
            status_code: status,
            response_body: body,
            response_headers: headers_to_map(headers),
            inserted_at: DateTime.utc_now()
          ]
        )
      else
        {0, nil}
      end

    case recorded do
      {1, _} ->
        :recorded

      _ ->
        release(hash)
        :released
    end
  end

  def hash_key(raw_key, token_id, method, path) do
    material = "#{raw_key}|#{token_id}|#{method}|#{path}"
    :crypto.hash(:sha256, material) |> Base.encode16(case: :lower)
  end

  @doc """
  Claim an idempotency row whose payload identity is carried by `scope`.

  Unlike `claim/2`, this transaction-bound variant never reclaims a pending
  row: its caller inserts the claim, performs the mutation, and completes the
  row in one database transaction. A rollback removes all three together.
  Reusing the same key with a different scope fails closed.
  """
  def claim_exact(hash, scope) when is_binary(hash) and is_binary(scope) do
    IdempotencyStore.claim_exact(hash, scope)
  end

  @doc """
  Complete one exact pending claim with a JSON receipt.

  The scope and pending-state predicates are load-bearing: completing a row
  claimed for another payload, or overwriting an existing replay, is refused.
  """
  def complete_exact(hash, scope, receipt)
      when is_binary(hash) and is_binary(scope) and is_map(receipt) do
    IdempotencyStore.complete_exact(hash, scope, receipt)
  end

  @doc """
  Reads one recent completed exact-operation receipt inside the caller's
  transaction and within an explicit scope-prefix allowlist.
  """
  defdelegate lookup_completed_exact(hash, allowed_scope_prefixes, max_age_seconds),
    to: IdempotencyStore

  defdelegate lookup_completed_exact(hash, allowed_scope_prefixes, max_age_seconds, now),
    to: IdempotencyStore

  @doc """
  Look up a COMPLETED cached response. A pending reservation (no response yet)
  returns `:miss` — there is nothing to replay.
  """
  def lookup(hash) when is_binary(hash) do
    case Repo.get(Key, hash) do
      %Key{state: "completed"} = row ->
        {:ok,
         %{
           status: row.status_code,
           body: row.response_body,
           headers: row.response_headers || %{}
         }}

      _ ->
        :miss
    end
  end

  @doc """
  Claim-first reservation. Atomically insert a pending row for `hash`.

  Returns:

    * `:claimed` — we own execution; caller runs the handler and then calls
      `complete/5` (success/4xx) or `release/1` (5xx/abort).
    * `{:replay, cached}` — a completed row already exists; replay it.
    * `:in_progress` — a FRESH pending row is held by a concurrent request;
      caller returns 409 `idempotency_key_in_use`. Never re-executes.
    * `:mismatch` — the row was claimed under a different `scope`. A mount
      that binds the request into its scope gets this when one key is
      reused for a different request; caller returns 422
      `idempotency_key_reused`. Never re-executes and never replays. (A row
      stored before the mutate mounts were bound is the transition exception:
      see `pre_binding_row?/2`.)

  A stale pending row (crashed reservation older than `pending_ttl_seconds`) is
  reclaimed in place and returns `:claimed`, but only under its own scope.
  """
  def claim(hash, scope) when is_binary(hash) and is_binary(scope) do
    claim(hash, scope, DateTime.utc_now(), 0)
  end

  # `attempt` bounds the swept-out / lost-reclaim retry loop; each branch that
  # recurses either narrows the row's state (pending→completed) or bumps
  # inserted_at to now (fresh), so the loop terminates well within the cap.
  defp claim(_hash, _scope, _now, attempt) when attempt >= 3, do: :in_progress

  defp claim(hash, scope, now, attempt) do
    row = %{
      key_hash: hash,
      scope: scope,
      state: "pending",
      status_code: nil,
      response_body: nil,
      response_headers: %{},
      inserted_at: now
    }

    case Repo.insert_all(Key, [row], on_conflict: :nothing, conflict_target: :key_hash) do
      {1, _} -> :claimed
      {0, _} -> resolve_conflict(hash, scope, now, attempt)
    end
  end

  defp resolve_conflict(hash, scope, now, attempt) do
    case Repo.get(Key, hash) do
      nil ->
        # Swept between our failed insert and this read — retry the whole claim.
        claim(hash, scope, DateTime.utc_now(), attempt + 1)

      # One key, two scopes: a request-bound mount saw the key reused for another
      # request. A pre-binding mutate row is the one exception (below).
      %Key{scope: other} = row when other != scope ->
        if pre_binding_row?(other, scope),
          do: resolve_row(row, hash, scope, now, attempt),
          else: :mismatch

      row ->
        resolve_row(row, hash, scope, now, attempt)
    end
  end

  defp resolve_row(%Key{state: "completed"} = row, _hash, _scope, _now, _attempt) do
    {:replay,
     %{status: row.status_code, body: row.response_body, headers: row.response_headers || %{}}}
  end

  # The write committed but no answer was recorded (the request process died
  # before before_send). Never reclaimed: running it again is the duplicate
  # this state exists to stop. It answers 409 until the sweep removes it.
  defp resolve_row(%Key{state: "committed"}, _hash, _scope, _now, _attempt), do: :in_progress

  defp resolve_row(%Key{state: "pending", inserted_at: ts}, hash, scope, now, attempt) do
    if stale?(ts, now), do: reclaim(hash, scope, now, attempt), else: :in_progress
  end

  defp resolve_row(_row, _hash, _scope, _now, _attempt), do: :in_progress

  # TRANSITION RULE, for the deploy that bound the mutate mounts to the request
  # (task-c65741be368a3f14). Before it they stored the bare scope "mutation",
  # with no fingerprint of the request. Such a row met by a bound mutate claim
  # ("mutation:<digest>") is treated as its own: completed replays, pending is
  # 409 or reclaimed. Refusing it 422 would tell a client whose write DID land
  # that it was refused. The row carries no body to compare, so a pre-deploy
  # key reused for a DIFFERENT body also replays, as every key did before the
  # binding. No mount writes a bare "mutation" row any more, and rows are swept
  # after ttl_seconds (24 h), so one day after that deploy this clause matches
  # nothing and can be deleted.
  defp pre_binding_row?("mutation", "mutation:" <> _digest), do: true
  defp pre_binding_row?(_stored, _scope), do: false

  # Atomically take over a stale (crashed) pending reservation. The WHERE clause
  # re-checks state+age so only ONE concurrent reclaimer wins; a loser re-resolves.
  defp reclaim(hash, scope, now, attempt) do
    cutoff = DateTime.add(now, -pending_ttl_seconds(), :second)

    query =
      from(k in Key,
        where: k.key_hash == ^hash and k.state == "pending" and k.inserted_at < ^cutoff
      )

    case Repo.update_all(query, set: [inserted_at: now, scope: scope]) do
      {1, _} -> :claimed
      {0, _} -> resolve_conflict(hash, scope, DateTime.utc_now(), attempt + 1)
    end
  end

  @doc """
  Mark a claimed reservation completed and cache its response. Called from
  `register_before_send` for status < 500. Returns the update count; a `0`
  means the reservation vanished (swept or reclaimed) and is surfaced by the
  caller — it is never a silent no-op.
  """
  def complete(hash, scope, status, body, headers)
      when is_binary(hash) and is_binary(scope) and is_integer(status) and is_binary(body) do
    query = from(k in Key, where: k.key_hash == ^hash)

    Repo.update_all(query,
      set: [
        state: "completed",
        scope: scope,
        status_code: status,
        response_body: body,
        response_headers: headers_to_map(headers),
        inserted_at: DateTime.utc_now()
      ]
    )
  end

  @doc """
  Release a pending reservation without caching a response (5xx or aborted
  request) so a retry can re-claim the key. Only deletes rows still `pending` —
  a concurrently-completed row is left intact.
  """
  def release(hash) when is_binary(hash) do
    from(k in Key, where: k.key_hash == ^hash and k.state == "pending")
    |> Repo.delete_all()
  end

  @doc """
  Legacy direct-store of a completed response (used by tests and any caller that
  already has the full response). Upserts a completed row; kept for the
  store/lookup round-trip contract.
  """
  def store(hash, scope, status, body, headers)
      when is_binary(hash) and is_binary(scope) and is_integer(status) and is_binary(body) do
    %Key{}
    |> Ecto.Changeset.change(%{
      key_hash: hash,
      scope: scope,
      state: "completed",
      status_code: status,
      response_body: body,
      response_headers: headers_to_map(headers),
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!(
      on_conflict:
        {:replace,
         [:scope, :state, :status_code, :response_body, :response_headers, :inserted_at]},
      conflict_target: :key_hash
    )
  end

  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -ttl_seconds(), :second)

    {n, _} =
      from(k in Key, where: k.inserted_at < ^cutoff)
      |> Repo.delete_all()

    n
  end

  @doc """
  ONE BOUNDED PASS of `sweep/1` — deletes at most `sweep_batch_limit` expired
  rows, OLDEST first, and returns how many it removed.

  `sweep/1` is a single unbounded DELETE. That is fine for a table that is
  swept regularly; it is not fine for the first pass over a table that has
  never been swept at all, which is exactly the state this store was in
  (`Barkpark.Idempotency.Sweeper` explains why). The subquery picks the oldest
  `limit` expired keys by primary key and the outer DELETE removes just those,
  so one statement is bounded no matter how deep the backlog is. Returning 0
  means "nothing left past the TTL" and is the loop's terminator.
  """
  @spec sweep_batch(DateTime.t()) :: non_neg_integer()
  def sweep_batch(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -ttl_seconds(), :second)

    victims =
      from(k in Key,
        where: k.inserted_at < ^cutoff,
        order_by: [asc: k.inserted_at],
        limit: ^sweep_batch_limit(),
        select: k.key_hash
      )

    {n, _} =
      from(k in Key, where: k.key_hash in subquery(victims))
      |> Repo.delete_all()

    n
  end

  defp stale?(nil, _now), do: true

  defp stale?(%DateTime{} = ts, now) do
    DateTime.diff(now, ts, :second) >= pending_ttl_seconds()
  end

  defp ttl_seconds do
    Application.get_env(:barkpark, :idempotency, [])
    |> Keyword.get(:ttl_seconds, @default_ttl_seconds)
  end

  defp pending_ttl_seconds do
    Application.get_env(:barkpark, :idempotency, [])
    |> Keyword.get(:pending_ttl_seconds, @default_pending_ttl_seconds)
  end

  defp sweep_batch_limit do
    Application.get_env(:barkpark, :idempotency, [])
    |> Keyword.get(:sweep_batch_limit, @default_sweep_batch_limit)
  end

  defp headers_to_map(list) when is_list(list), do: Map.new(list)
  defp headers_to_map(%{} = m), do: m
  defp headers_to_map(_), do: %{}
end
