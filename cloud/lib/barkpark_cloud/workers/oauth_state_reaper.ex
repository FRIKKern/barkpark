defmodule BarkparkCloud.Workers.OAuthStateReaper do
  @moduledoc """
  Per-minute hygiene sweep of expired single-use OAuth `state` nonces — the
  structural twin of `DeviceAuthReaper`, on the same `:maintenance` queue.

  Same story as its twin: an abandoned flow leaves a dead row. Both OAuth GET
  legs `Repo.insert!` an `oauth_states` row per hit (`mint_state/1`, one call
  deep inside `OAuth.authorize_url/1`) on an UNAUTHENTICATED route, and the only
  DELETE anywhere in `cloud/` was `consume_state/2`'s single REDEEMED row. Every
  user who bounced off the IdP consent screen — and every scanner that ever hit
  the initiator — left a row behind forever. Unauthenticated unbounded growth.

  Expiry is already enforced IN BAND, twice: `verify_state/2` rejects a payload
  whose `exp <= now` before it queries at all, and `consume_state/2`'s DELETE
  itself filters `expires_at > now`. So a lapsed nonce is dead to redemption the
  instant its 600s TTL passes and correctness never depends on this worker
  running — it only stops the tombstones accumulating.

  NO GRACE WINDOW, deliberately: `OAuth.reap_expired_states/0` deletes at
  `expires_at <= now` exactly, matching `DeviceAuthReaper`. The more visually
  similar sibling `AgentRetentionWorker` DOES apply a day-scale grace, and the
  difference is real rather than an oversight: its rows stay READABLE evidence
  (agent history someone may still want to inspect) past their retention date,
  so deleting on the stroke of the boundary would destroy data still in use. A
  lapsed OAuth nonce is the opposite — unredeemable by construction and evidence
  of nothing. A grace window here would buy only a longer-lived pile of rows
  whose entire purpose has already expired.

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
    {:ok, BarkparkCloud.OAuth.reap_expired_states()}
  end
end
