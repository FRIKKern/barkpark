defmodule Barkpark.Audit.ExportWorker do
  @moduledoc """
  Oban cron worker that flushes the audit log to every candidate SIEM export
  sink once a minute (`Barkpark.Audit.Export.flush/0`).

  Candidates are the active sinks PLUS any auto-disabled sink whose backoff
  cooldown has elapsed — this tick carries the half-open probe that lets a
  latched sink recover on its own. A receiver outage therefore costs a bounded
  gap in SIEM ingestion, never a permanent one.

  `max_attempts: 1` because retry is inherent to the cursor model — a failed
  flush does not advance the sink's `last_exported_id`, so the next tick
  re-attempts the same events. No fencing is needed: `flush/0` only advances a
  cursor forward on a confirmed 2xx, and concurrent flushes of the same sink are
  idempotent (both read from the same high-water mark and advance to the same
  max id, and both clear the same latch to the same clean state).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Barkpark.Audit.Export

  @impl Oban.Worker
  def perform(_job) do
    Export.flush()
    :ok
  end
end
