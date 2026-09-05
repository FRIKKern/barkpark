defmodule Barkpark.Idempotency.Sweeper do
  @moduledoc """
  The GC that `Barkpark.Idempotency` documented and nobody ran.

  `Idempotency.sweep/1` deletes `idempotency_keys` rows past
  `:idempotency, :ttl_seconds` (24h). It has existed since the table was
  created — and until this worker, `grep -rn 'Idempotency.sweep' api/` matched
  exactly ONE call site: `api/test/barkpark/idempotency_test.exs`. Nothing in
  `lib/`, nothing in the Oban crontab, nothing in the supervision tree. The
  dedup store was therefore APPEND-ONLY in production: every keyed mutation
  wrote a row carrying its full cached `response_body` (a `:text` column — a
  mutate receipt, not a status line) and no row was ever removed.

  That is the "a key table that only grows is the next filing" hazard, and
  handing `bp task create` an `Idempotency-Key` (this row's C3) is exactly what
  turns a store used by a handful of callers into one written on every task
  create in the fleet. The GC has to exist BEFORE the traffic does.

  ## Bounded by construction

  `Idempotency.sweep/1` is a single unbounded `DELETE ... WHERE inserted_at <
  cutoff`. On a table that has never been swept, the first pass would be one
  long transaction over the entire accumulated backlog. This worker instead
  drives `Idempotency.sweep_batch/1`, which deletes at most
  `:idempotency, :sweep_batch_limit` (default 5_000) rows per statement, and
  loops at most `@max_passes` times per tick. A backlog larger than
  `limit * max_passes` is simply finished on the next tick — nothing starves,
  because every pass takes the OLDEST rows first.

  ## Why hourly, not per-minute

  The TTL is 24h; an hour of lateness on a 24h expiry is not a correctness
  property, and the sweep is an index scan on `idempotency_keys(inserted_at)`
  (that index has existed since the create migration — no new storage, no new
  index, nothing to migrate for this worker). The per-minute crontab slots
  (webhook/audit/playground/task-TTL) are all recovery paths where lateness IS
  the cost. This one is housekeeping.

  A tick over an empty backlog is a no-op: the first batch deletes 0 rows, the
  loop exits, `%{deleted: 0, passes: 1}`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.Idempotency

  # Bounds one tick's work. limit(5_000) * 20 = 100k rows per hourly tick, far
  # above any plausible hourly keyed-mutation rate — so in steady state the loop
  # exits on the first short pass, and only a cold first sweep of a long-unswept
  # table ever uses more than one.
  @max_passes 20

  @impl Oban.Worker
  def perform(%Oban.Job{} = _job), do: {:ok, sweep()}

  @doc """
  Pure entry point — bypasses `Oban.Job` wrapping so tests can drive the sweep
  deterministically. Returns `%{deleted: N, passes: P}`.
  """
  @spec sweep(DateTime.t()) :: %{deleted: non_neg_integer(), passes: pos_integer()}
  def sweep(now \\ DateTime.utc_now()) do
    result = do_sweep(now, 0, 1)

    if result.deleted > 0 do
      Logger.info(
        "Idempotency.Sweeper removed #{result.deleted} expired key(s) in #{result.passes} pass(es)"
      )
    end

    result
  end

  defp do_sweep(now, deleted, pass) do
    case Idempotency.sweep_batch(now) do
      0 ->
        %{deleted: deleted, passes: pass}

      n when pass >= @max_passes ->
        # Backlog outlived the tick's budget. Deliberately NOT an error: the
        # next tick resumes at the oldest remaining row.
        %{deleted: deleted + n, passes: pass}

      n ->
        do_sweep(now, deleted + n, pass + 1)
    end
  end
end
