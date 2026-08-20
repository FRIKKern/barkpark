defmodule BarkparkCloud.Workers.SseTicketReaper do
  @moduledoc """
  Per-minute hygiene sweep of burned and expired SSE stream tickets — the third
  reaper on the `:maintenance` queue, structurally identical to
  `OAuthStateReaper` and `DeviceAuthReaper`.

  Same defect class as both twins: a row nothing ever deletes. `POST
  /v1/auth/sse-ticket` mints one `user_tokens` row per call with a 60s TTL, and
  `Accounts.consume_sse_ticket/1` BURNS a redeemed ticket by stamping
  `revoked_at` inside a `FOR UPDATE` transaction — it never DELETEs. Before this
  worker, the only delete-by-context anywhere in `Accounts` was
  `delete_two_factor_pending_tokens/1`, which is 2FA-only, so a console tab's
  reconnect loop accreted one dead row per connect, forever.

  Expiry is already enforced IN BAND: `consume_sse_ticket/1` filters
  `is_nil(revoked_at)` and `expires_at > now` before it will resolve a user, so a
  burned or lapsed ticket is dead to redemption the instant either becomes true.
  Correctness never depends on this worker running — it only stops the pile.

  ## A THROTTLE WAS CONSIDERED AND REJECTED

  The obvious alternative — rate-limit the mint route — is deliberately NOT what
  this is, and the two are not complements here:

    * The mint is NON-SUPERSEDING **on purpose**. `create_sse_ticket/1` never
      revokes the user's other live tickets, because two console tabs each hold
      their own: a mint in one evicting the other's unredeemed ticket makes that
      tab 401, which makes it remint, which evicts the first — a mutual-eviction
      storm, one junk 401 per turn. A per-user mint throttle re-opens that same
      wound from the other side: it would 429 a legitimate second or third tab's
      reconnect, which is exactly the failure the non-superseding design exists
      to avoid.
    * The throttles that DO live on this surface guard something else.
      `@confirm_throttle` (1/300s) and `@change_email_throttle` (3/3600s) in
      `Accounts` exist to stop spam EMAIL DELIVERY — an outbound side effect with
      a real-world cost. An authenticated bare row insert is not that.
    * The sibling class was already paid this way, twice. `OAuthStateReaper`
      (unbounded `oauth_states` growth) and `DeviceAuthReaper` (abandoned device
      flows) are the doubled precedent already on `:maintenance`. Unbounded table
      growth with no reaper is the defect; a reaper is its established payment.

  Since each row's USEFUL life is already bounded by its 60s TTL plus
  `revoked_at`, what was left was purely a hygiene problem — so it gets the
  hygiene fix.

  ## COVERAGE BOUNDARY — what this does NOT do

  This worker bounds the RESIDUE, not the MINT RATE. There is still no limit on
  how many `"sse"` rows one authenticated caller can create: a hot loop can
  insert an unbounded number of rows within any single minute between sweeps, and
  every one of them is live (and redeemable) until it is burned or lapses. What
  is guaranteed is only that dead rows do not survive the next tick. If a
  burst-rate bound is ever wanted, it is a separate, differently-shaped guard on
  the route — and it must answer the two-tab storm above before it ships.

  NO GRACE WINDOW, deliberately — mirroring `OAuthStateReaper`. The delete fires
  at `revoked_at IS NOT NULL OR expires_at <= now` exactly. The visually similar
  `AgentRetentionWorker` DOES apply a day-scale grace, and the difference is real
  rather than an oversight: its rows stay READABLE evidence someone may still
  want to inspect. A burned single-use ticket is the opposite — it holds no
  plaintext (only a SHA-256 hash), it is unredeemable by construction, and it is
  evidence of nothing. A grace window would buy only a longer-lived pile.

  Idempotent: a sweep that finds nothing returns `{:ok, %{reaped: 0}}` and never
  raises. The `unique` window (60s) collapses a slow sweep plus the next cron
  tick into one in-flight job instead of stacking.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, BarkparkCloud.Accounts.reap_sse_tickets()}
  end
end
