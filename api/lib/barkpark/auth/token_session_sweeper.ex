defmodule Barkpark.Auth.TokenSessionSweeper do
  @moduledoc """
  The GC for `token_sessions` (task-781cc7f06c5f4335, ruling #16 rework half
  follow-up to task-57f23825b18ab55d) — the same shape
  `Barkpark.Auth.LoginTicketSweeper` and `Barkpark.PreviewToken.Sweeper`
  already carry for their own append-only tables, so `token_sessions` does
  not repeat the history both of their moduledocs document: a sweep function
  that existed and nothing ever called outside its own test.

  ## What the rows are — this one holds a live credential

  `Barkpark.Auth.TokenSession` binds `raw_token` — the RAW bearer a browser
  token sign-in presented, not a hash — as a `Barkpark.EncryptedBinary`
  (Cloak AES-GCM) field, so `Auth.resolve_session_credential/2` can hand it
  back for a Web Component's `data-token=` attribute. The same property
  `LoginTicketSweeper`'s moduledoc states for `login_tickets` holds here: a
  plain `Repo.one/1` (or `Repo.all/1`) load of a live row DECRYPTS the
  column, so an unswept expired-or-revoked row is a retained, re-usable
  credential for anyone who can read the table — a dump, a replica, a
  backup, any code with `Repo` — not merely stale housekeeping.

  Logout (`Auth.revoke_token_session/1`) already DELETES the row it names,
  for exactly this reason (see `TokenSession`'s own moduledoc) — so a
  normally-terminated session leaves nothing for this worker to find. What
  this worker reaps is the population logout never reaches:

    * a session that expired naturally (the 30-day default validity) because
      the browser was never signed out of explicitly (closed, crashed, the
      cookie simply outlived its use) — `expires_at <= now`;
    * a row some OTHER path flagged `revoked_at` without deleting it — the
      idempotent kill-switch `TokenSession`'s moduledoc names as a backstop
      for "a future cascade off `Auth.revoke_token/1`" that does not itself
      exist yet. This worker is what makes that flag meaningful: today
      nothing SETS it, but nothing SWEEPS it either, and the two must ship
      together or the flag is decoration.

  ## Why hourly, not per-minute

  Unlike `login_tickets` (60s TTL, no grace — the cadence IS the retention
  floor), the floor here is `@token_session_default_validity_days` (30 days,
  `Barkpark.Auth`). Sweeping per-minute cannot evict a row any sooner than
  its own 30-day `expires_at` already allows, so per-minute would buy
  nothing for 1440x the statements. This follows `PreviewToken.Sweeper`'s
  reasoning exactly: hourly bounds the table at roughly 30 days plus one
  tick of lateness, which is the property that matters, and it belongs with
  the housekeeping GCs (`:17`/`:43` slots) rather than the per-minute
  recovery-path slots (webhook/audit/playground/task-TTL), where lateness
  IS the cost.

  Offset to `:50` so this hourly GC's range delete never opens in the same
  tick as the idempotency sweep (`:17`) or the preview-token sweep (`:43`).

  ## Bounded by construction

  `Auth.sweep_token_sessions/1` is a single unbounded `DELETE ... WHERE
  expires_at <= now OR revoked_at IS NOT NULL`. This worker instead drives
  `Auth.sweep_token_sessions_batch/1`, which deletes at most
  `:token_session, :sweep_batch_limit` (default 5_000) rows per statement,
  oldest `expires_at` first, and loops at most `@max_passes` times per tick
  — so a cold first pass over a long-unswept table cannot become one giant
  transaction, the same bound `LoginTicketSweeper`/`PreviewToken.Sweeper`
  both carry.

  The sweep predicate's `expires_at` half is served by
  `unique_index(:token_sessions, [:session_hash])`'s sibling index on
  `api_token_id` existing already for the FK, but `expires_at` itself has no
  index yet — accepted for the same reason `PreviewToken.Sweeper` and
  `LoginTicketSweeper` both accept a seq scan over their own small tables:
  hourly ticks keep `token_sessions` small (one row per live browser
  session, swept within ~30 days plus one tick), so the scan stays cheap. A
  dedicated index is a separate decision if the table's steady-state size
  argues for one later.

  A tick over an empty backlog is a no-op: the first batch deletes 0 rows,
  the loop exits, `%{deleted: 0, passes: 1}`.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.Auth

  # Bounds one tick's work. limit(5_000) * 20 = 100k rows per hourly tick, far
  # above any plausible hourly sign-in rate — so in steady state the loop
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
        "Auth.TokenSessionSweeper removed #{result.deleted} expired/revoked token_session(s) in #{result.passes} pass(es)"
      )
    end

    result
  end

  defp do_sweep(now, deleted, pass) do
    case Auth.sweep_token_sessions_batch(now) do
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
