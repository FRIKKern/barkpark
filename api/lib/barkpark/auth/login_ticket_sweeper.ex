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

  Consuming the ticket does NOT revoke the bound token — it cannot, because the
  bound token is the operator's real long-lived api_token, which is the whole
  point of the handoff. So every retained row is a retained re-entry credential.

  `Barkpark.Auth.LoginTicketSweeperTest` measures this rather than arguing it:
  a plain Ecto load of an EXPIRED-BUT-UNUSED row returns the bearer in
  plaintext (the bytes at rest are ciphertext — also asserted), and presenting
  it to `POST /v1/auth/login-tickets` returns **201** where a garbage bearer
  and no bearer both return 401. The recovered bearer does not merely
  authenticate; it mints a fresh handoff ticket.

  ## THIS WORKER IS NOT THE RETENTION BOUNDARY FOR SPENT ROWS

  It was, for one release, and that was the wrong place for it
  (task-62e7b342b85e88fe, the durable half of task-e4d5cc40193a3ef5 / #16543).
  `Auth.consume_login_ticket/1` now DELETES the row it wins instead of stamping
  `used_at` on it, so a successful consume leaves nothing behind and the
  retention window for a CONSUMED ticket is **zero**, not one tick. Nothing
  about this worker's cadence bounds that any more, and no future change to the
  cadence may be reasoned about as if it did.

  What still reaches the `used_at IS NOT NULL` half of the predicate is exactly
  two things: rows stamped by the pre-#16555 consume, which exist in any
  already-deployed database until this worker takes them, and any future
  regression that reintroduces a stamping consume. Both are backstops, not the
  design.

  ## The accepted residue: EXPIRED-BUT-UNUSED

  A ticket that is minted and then never consumed has NO consume event to hook,
  so nothing but a sweep can remove it. That arm is this worker's, and its
  window is a DECISION, recorded here rather than left to fall out of the
  cadence:

  > **ACCEPTED RESIDUE — up to ~120 seconds.** A minted-and-abandoned login
  > ticket's bearer stays recoverable from `login_tickets` for at most its 60s
  > TTL plus one tick of this per-minute worker (60s) = **~2 minutes**. It is
  > accepted because the row is only reachable by an actor who already holds
  > database or backup access, the bearer it holds is the operator's own token
  > (which that actor could reach by other means at that access level), and the
  > alternative — a delete-on-expiry trigger or a sub-minute cadence — buys a
  > sub-two-minute improvement against that same actor. Shortening the tick,
  > not lengthening it, is the direction any revision may take.

  ## Why every minute

  The TTL is **60 seconds**, and unlike `Barkpark.PreviewToken.Sweeper` there
  is no grace window at all: an unconsumed row is eligible 60s after it is
  minted. Nothing downstream of the sweep sets a floor — so THE CADENCE IS THE
  RETENTION FLOOR FOR THE EXPIRED-BUT-UNUSED ARM, one for one. (For the spent
  arm it is not: see above — the consume deletes.)

  That is the whole argument, and it is why this worker does not copy its
  siblings' hourly slot. Hourly would leave a live re-entry credential readable
  for up to ~1h past a documented 60-second life — the cadence would be 60x the
  TTL it is supposed to enforce. Per-minute takes the worst case to ~2 minutes
  (one TTL plus one tick of lateness), which is the accepted residue above. The
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
