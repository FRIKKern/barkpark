defmodule BarkparkCloud.Workers.ContentWebhookReconciler do
  @moduledoc """
  dr-w11 — the scheduled half of "a site that missed its content-publish webhook
  never gets one, and nothing says so".

  THE HOLE. `Registry.ensure_content_webhook/2` had exactly two callers: the
  inline `:create` registration and an explicit human backfill. Nothing else. So
  a site whose create-time registration failed stayed unregistered FOREVER and
  every content publish on its dataset reached nothing — guerrilla's `auto-proof`
  422'd inside a 20-minute defect window on 2026-07-14 and its `updated_at` still
  equals its `inserted_at` to the microsecond, 8 weeks later. `sites` carries no
  column recording registration state, so no query could even find it.

  This worker runs hourly on the `:maintenance` queue (the config.exs Cron entry)
  and calls `Registry.reconcile_content_webhooks/1` — bounded, idempotent, and in
  the NARROW `:reconcile` mode that POSTs a genuinely missing row and no-ops on a
  row that exists. It deliberately does NOT re-assert `active: true` on existing
  rows the way the explicit backfill does: a schedule cannot infer that a human
  who disabled a hook by hand wanted it back on. The re-assert stays a verb a
  person runs (`bp cloud webhook reconcile`, `ensure_content_webhook/2`).

  HOURLY, NOT PER-MINUTE, and that is the box-call budget rather than urgency:
  each swept site costs a cross-host webhook LIST against its own box. The fault
  it repairs is a create-time one-shot measured in weeks, so a per-minute sweep
  would buy nothing and multiply the fan-out by 60.

  WHAT IT STRUCTURALLY CANNOT REPAIR, said out loud because the tally would
  otherwise read as a clean bill of health: a content-bound site that carries no
  content-publish SECRET. `ensure_content_webhook/2` reveals a secret, it never
  mints one, so those sites are outside `list_content_webhook_sites/1` entirely.
  Six of guerrilla's eight uncovered sites are in exactly that state. They are
  the reason this ships with its twin — `Registry.publish_trigger/1`, the derived
  `publish_trigger` on every site payload, which reports them `:absent`.

  Idempotent and never raising: a sweep that finds nothing returns
  `{:ok, %{swept: 0, registered: 0, present: 0, skipped: 0, errored: 0}}`, and one
  unreachable box lands in `errored` while every later site is still attempted.
  The `unique` window collapses a slow sweep plus the next cron tick to one
  in-flight job instead of stacking.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Spans the whole hourly period, and must list ALL incomplete states or Oban
    # warns that a job parked in an omitted state would slip the guard.
    unique: [
      period: 3600,
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, BarkparkCloud.Registry.reconcile_content_webhooks()}
  end
end
