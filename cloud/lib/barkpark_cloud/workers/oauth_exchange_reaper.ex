defmodule BarkparkCloud.Workers.OAuthExchangeReaper do
  @moduledoc """
  Per-minute hygiene sweep of burned and expired OAuth exchange codes — the fourth
  reaper on the `:maintenance` queue, structurally identical to `OAuthStateReaper`,
  `DeviceAuthReaper` and `SseTicketReaper`.

  IT SHIPS IN THE SAME DIFF AS THE MINT IT CLEANS UP, and that is the whole point.
  The two nearest precedents on this exact surface were both "a row nothing ever
  deletes" findings discovered LATER: `oauth_states` grew one tombstone per bounced
  consent screen (cch-w2), and `"sse"` grew one per console reconnect (cch-w3).
  `Accounts.create_oauth_exchange_code/2` is the same shape — a bare `Repo.insert`
  on the tail of an unauthenticated route — and `consume_oauth_exchange_code/1`
  burns by stamping `revoked_at`, never by DELETE. Left unreaped, every sign-in
  (and every abandoned one) would leave a permanent `user_tokens` row.

  Expiry is already enforced IN BAND: `consume_oauth_exchange_code/1` filters
  `is_nil(revoked_at)` and `expires_at > now` before it will resolve a user, so a
  burned or lapsed code is dead to redemption the instant either becomes true.
  Correctness never depends on this worker running — it only stops the pile.

  NO GRACE WINDOW, deliberately — mirroring `OAuthStateReaper` and
  `SseTicketReaper`. A burned single-use code holds no plaintext (only a SHA-256
  hash), is unredeemable by construction, and is evidence of nothing: the session
  it minted is its own audit row in the active-sessions list, carrying the
  `origin: "oauth:<provider>"` this code's `sent_to` handed over. A grace window
  would buy only a longer-lived pile.

  ## COVERAGE BOUNDARY — what this does NOT do

  This bounds the RESIDUE, not the MINT RATE. The mint runs once per SUCCESSFUL
  OAuth callback, which is already gated by a single-use `state` nonce, so the
  unbounded-insert vector `SseTicketReaper` documents for its own route does not
  exist here. The rate limit that does exist (`"oauth_exchange:" <> peer_ip`, 30/min)
  guards the REDEMPTION endpoint against code-guessing, not the mint.

  Idempotent: a sweep that finds nothing returns `{:ok, %{reaped: 0}}` and never
  raises. The `unique` window (60s) collapses a slow sweep plus the next cron tick
  into one in-flight job instead of stacking.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, BarkparkCloud.Accounts.reap_oauth_exchange_codes()}
  end
end
