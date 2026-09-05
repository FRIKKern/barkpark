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
  """

  import Ecto.Query
  require Logger
  alias Barkpark.Repo

  @default_ttl_seconds 86_400
  @default_pending_ttl_seconds 60
  # Upper bound on rows one `sweep_batch/1` statement removes.
  @default_sweep_batch_limit 5_000

  defmodule Key do
    use Ecto.Schema

    @primary_key {:key_hash, :string, autogenerate: false}

    schema "idempotency_keys" do
      field :scope, :string
      # "pending" = reservation held, handler executing; "completed" = response cached.
      field :state, :string, default: "pending"
      field :status_code, :integer
      field :response_body, :string
      field :response_headers, :map, default: %{}
      field :inserted_at, :utc_datetime_usec
    end
  end

  def hash_key(raw_key, token_id, method, path) do
    material = "#{raw_key}|#{token_id}|#{method}|#{path}"
    :crypto.hash(:sha256, material) |> Base.encode16(case: :lower)
  end

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

  A stale pending row (crashed reservation older than `pending_ttl_seconds`) is
  reclaimed in place and returns `:claimed`.
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

      %Key{state: "completed"} = row ->
        {:replay,
         %{status: row.status_code, body: row.response_body, headers: row.response_headers || %{}}}

      %Key{state: "pending", inserted_at: ts} ->
        if stale?(ts, now), do: reclaim(hash, scope, now, attempt), else: :in_progress

      _ ->
        :in_progress
    end
  end

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
