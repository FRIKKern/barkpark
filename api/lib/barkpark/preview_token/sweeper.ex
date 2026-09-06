defmodule Barkpark.PreviewToken.Sweeper do
  @moduledoc """
  The GC that `Barkpark.PreviewToken` documented and nobody ran.

  `PreviewToken.sweep/1` deletes `preview_token_jti` rows whose `expires_at` is
  more than `@grace_seconds` (1h) in the past. It has existed since the table
  was created — and until this worker, `git grep -rn 'PreviewToken.sweep'`
  matched exactly TWO call sites, both in
  `api/test/barkpark/preview_token_test.exs`. Nothing in `lib/`, nothing in the
  Oban crontab, nothing in the supervision tree. `record_jti/1`'s own docstring
  promises that "`sweep/1` reaps rows past the grace period so the table does
  not grow unbounded" — a promise the code kept and the schedule did not.

  The table was therefore APPEND-ONLY in production: one row per preview-token
  request, forever, on a table that `record_jti/1` INSERTs into and
  `revoked?/1` SELECTs from on the hot path of EVERY preview request.

  ## What the rows are, and what they are not

  Worth stating precisely, because "expired credential store" would overstate
  it. A row holds `jti` (a random `Ecto.UUID`), `token_id`, `dataset`,
  `doc_ids`, `issued_at`, `expires_at`, `revoked_at`. It holds NO secret
  material: not the JWT, not its HMAC signature, not the signing secret. The
  JTI is an identifier, not a bearer — possessing one forges nothing.

  So the case for this worker is retention and growth, not secret exposure:
  the table is an unbounded, permanently retained record of which API token
  previewed which document ids in which dataset. This repo already treats an
  access trail of that shape as needing a TTL — `paper_access_log` has
  `Content.Workers.PaperAccessSweeper` on the same crontab for exactly that
  reason. This entry brings `preview_token_jti` in line.

  ## Deleting replay-protection rows is safe

  The one thing a GC over this table must never do is make an expired token
  usable again. It cannot: `verify/2` runs `check_expiry` BEFORE
  `check_revocation`, so a token past `exp` is rejected on expiry whether or
  not its JTI row survives. The 1h grace is the clock-skew margin on top of
  that. `preview_token_sweeper_test.exs` pins this invariant, because a
  refactor that reordered those two checks would silently turn this worker into
  a replay hole.

  ## Bounded by construction

  `PreviewToken.sweep/1` is a single unbounded `DELETE ... WHERE expires_at <
  cutoff`. On a table that has never been swept, the first pass would be one
  long transaction over the entire accumulated backlog. This worker instead
  drives `PreviewToken.sweep_batch/1`, which deletes at most
  `:preview_token, :sweep_batch_limit` (default 5_000) rows per statement, and
  loops at most `@max_passes` times per tick. A backlog larger than
  `limit * max_passes` is finished on the next tick — nothing starves, because
  every pass takes the OLDEST rows first.

  ## Why hourly

  Unlike the 24h idempotency TTL, the lifetime here is short: a 10-minute
  default token TTL plus a 1h grace, so a row becomes eligible ~70 minutes
  after it is written. The FLOOR on retention is therefore set by the grace
  window, not by the cadence — sweeping per-minute could not push a row out
  any sooner than the 1h grace already allows, so it would buy nothing for 60x
  the statements. Hourly bounds the table at roughly two hours of preview
  traffic (one grace window plus at most one tick of lateness), which is the
  property that matters. The per-minute crontab slots
  (webhook/audit/playground/task-TTL) are recovery paths where lateness IS the
  cost; this is housekeeping.

  The sweep predicate is served by `index(:preview_token_jti, [:expires_at])`,
  created in `20260417230200_create_preview_token_jti.exs` alongside the table
  — so this worker needs no migration and adds no index.

  A tick over an empty backlog is a no-op: the first batch deletes 0 rows, the
  loop exits, `%{deleted: 0, passes: 1}`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.PreviewToken

  # Bounds one tick's work. limit(5_000) * 20 = 100k rows per hourly tick, far
  # above any plausible hourly preview-request rate — so in steady state the
  # loop exits on the first short pass, and only a cold first sweep of a
  # long-unswept table ever uses more than one.
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
        "PreviewToken.Sweeper removed #{result.deleted} expired JTI row(s) in #{result.passes} pass(es)"
      )
    end

    result
  end

  defp do_sweep(now, deleted, pass) do
    case PreviewToken.sweep_batch(now) do
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
