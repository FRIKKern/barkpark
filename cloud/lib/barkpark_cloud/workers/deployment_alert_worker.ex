defmodule BarkparkCloud.Workers.DeploymentAlertWorker do
  @moduledoc """
  Delivers ONE `:deployment_failed` alert for ONE site, off the sweep's tick.

  ## Why this exists (the cap it replaces)

  `Registry.reap_stale_deployments/0` runs every minute on the `maintenance`
  queue and its four bulk passes can fail hundreds of rows in a single tick.
  `Notifications.dispatch_event/3`'s EMAIL leg is synchronous, so that fan-out
  used to be hundreds of blocking `Mailer.deliver` calls inside one cron tick —
  and the shipped mitigation was a CAP: alert the first 25 deployments, write a
  `suppressed` withhold row for the rest, and tell the 26th owner nothing by
  mail. See `Registry.reap_stale_deployments/0` and
  `Notifications.Withhold.label/1`'s `:reap_alert_cap` arm for the policy that
  stood before this worker.

  The cap existed because the SEND was on the sweep's thread. It is not on the
  sweep's thread any more: the reaper enqueues one job per reaped deployment and
  returns, so the fan-out costs one `oban_jobs` INSERT for the whole sweep and
  the mail spends the queue's concurrency instead of the cron tick's. The cap and
  its suppression branch are therefore deleted, not raised — an uncapped fan-out
  whose cost is one insert needs no ceiling to protect the tick.

  ## Queue: `:default`, alongside `ChatNotificationWorker`

  DELIBERATELY the same queue the chat leg already uses, and NOT a new
  `notifications` queue: `config/runtime.exs` rebuilds `:queues` from a literal
  `[default: 10, maintenance: 2]` in prod, so a queue added only in
  `config/config.exs` would never be drained on the live control plane and its
  jobs would accrue forever — a worse silence than the cap.

  ## Retry semantics

  `Notifications.dispatch_site_event/3` never raises and returns `:ok` for a
  since-deleted site, so a job either sends or lands a `failed`/`suppressed`
  `Delivery` row through the dispatcher's own funnel. `max_attempts: 1` follows
  from that: a second attempt would re-mail every recipient the first attempt
  reached, because the dispatcher has no per-recipient resume point. The retry
  seam for a failed send is the `Delivery` row, exactly as `Delivery`'s moduledoc
  documents — not this worker.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias BarkparkCloud.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id} = args}) do
    payload = Map.get(args, "payload") || %{}

    # The payload rides as JSON, so its keys arrive as STRINGS. Nothing here
    # atomizes them: `Notifications.Render.deployment_identity/1`,
    # `EventEmail`'s `name/1` and its `detail/1` all read every key under both a
    # string and an atom already (they must — the chat leg has always fed them an
    # Oban args map), so the string-keyed map renders byte-identically to the
    # atom-keyed one the synchronous producers pass.
    Notifications.dispatch_site_event(site_id, :deployment_failed, payload)
  end
end
