defmodule Barkpark.Auth.LoginTicketSweeper do
  @moduledoc """
  The GC that `Barkpark.Auth` documented and nobody ran.

  `Auth.sweep_login_tickets/0` deletes `login_tickets` rows that are spent
  (`used_at` set) or expired (`expires_at <= now`). It has existed since the
  table was created — and until this worker, `git grep -rn 'sweep_login_tickets'`
  matched exactly TWO lines: the definition in `api/lib/barkpark/auth.ex` and
  ONE test caller in
  `api/test/barkpark_web/controllers/login_ticket_test.exs`. Nothing in `lib/`,
  nothing in the Oban crontab, nothing in the supervision tree. `login_tickets`
  was therefore APPEND-ONLY in production.

  ## What the rows are — this one holds a live credential

  Worth stating precisely, because the sibling sweepers do not have this
  property and it is what sets this worker's cadence. `Barkpark.Auth.LoginTicket`
  binds `api_token` — the RAW operator bearer, not a hash, not an identifier —
  as a `Barkpark.EncryptedBinary` (Cloak AES-GCM) field, so `consume_login_ticket/1`
  can drop the raw token into the browser session.

  Consuming the ticket stamps `used_at`. It does NOT delete the row and it does
  NOT revoke the bound token — it cannot, because the bound token is the
  operator's real long-lived api_token, which is the whole point of the
  handoff. So every un-swept row is a retained re-entry credential.

  `Barkpark.Auth.LoginTicketSweeperTest` measures this rather than arguing it:
  a plain Ecto load of a SPENT row and of an EXPIRED-BUT-UNUSED row returns the
  bearer in plaintext (the bytes at rest are ciphertext — also asserted), and
  presenting it to `POST /v1/auth/login-tickets` returns **201** where a
  garbage bearer and no bearer both return 401. The recovered bearer does not
  merely authenticate; it mints a fresh handoff ticket.

  ## Why every minute

  The TTL is **60 seconds**, and unlike `Barkpark.PreviewToken.Sweeper` there
  is no grace window at all: a row is eligible the moment it is spent, or 60s
  after it is minted if it never was. Nothing downstream of the sweep sets a
  floor — so THE CADENCE IS THE RETENTION FLOOR, one for one.

  That is the whole argument, and it is why this worker does not copy its
  siblings' hourly slot. Hourly would leave a live re-entry credential readable
  for up to ~1h past a documented 60-second life — the cadence would be 60x the
  TTL it is supposed to enforce. Per-minute takes the worst case to ~2 minutes
  (one TTL plus one tick of lateness), which is the property that matters. The
  other per-minute slots (webhook/audit/playground/task-TTL) are the ones where
  lateness IS the cost; this one belongs with them, not with the housekeeping
  GCs at `:17` and `:43`.

  The sibling GCs offset their minute so two hourly range deletes never open in
  the same tick. A per-minute entry has no minute to offset — it necessarily
  coincides with the other per-minute slots. What makes that safe is the bound
  below, not the schedule: `login_tickets` in steady state holds at most ~2
  minutes of mint traffic, and only the cold first pass over the never-swept
  backlog is ever large.

  ## Bounded by construction

  `Auth.sweep_login_tickets/0` is a single unbounded `DELETE ... WHERE used_at
  IS NOT NULL OR expires_at <= now`. On a table that has never been swept, the
  first pass would be one long transaction over the entire accumulated backlog.
  This worker instead drives `Auth.sweep_login_tickets_batch/1`, which deletes
  at most `:login_ticket, :sweep_batch_limit` (default 5_000) rows per
  statement, and loops at most `@max_passes` times per tick. A backlog larger
  than `limit * max_passes` is finished on the next tick — nothing starves,
  because every pass takes the OLDEST rows first (`expires_at ASC`).

  ## Index

  The sweep predicate reads `used_at` and `expires_at`. The create migration
  (`20260702120000_create_login_tickets.exs`) creates
  `index(:login_tickets, [:expires_at])` and nothing on `used_at`, so the
  `expires_at` half of the OR and the `ORDER BY expires_at` are served and the
  `used_at IS NOT NULL` half is not — an OR across an indexed and an unindexed
  column will not use the index for the predicate as a whole. This worker adds
  NO migration by design (that is a separate decision): the bounded batch is
  what keeps a seq scan over a small table cheap, and per-minute ticks keep the
  table small.

  A tick over an empty backlog is a no-op: the first batch deletes 0 rows, the
  loop exits, `%{deleted: 0, passes: 1}`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.Auth

  # Bounds one tick's work. limit(5_000) * 20 = 100k rows per tick, far above
  # any plausible per-minute login-handoff rate — so in steady state the loop
  # exits on the first short pass, and only a cold first sweep of a
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
        "Auth.LoginTicketSweeper removed #{result.deleted} spent/expired login ticket(s) in #{result.passes} pass(es)"
      )
    end

    result
  end

  defp do_sweep(now, deleted, pass) do
    case Auth.sweep_login_tickets_batch(now) do
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
