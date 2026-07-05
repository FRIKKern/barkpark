defmodule Barkpark.Audit.ExportWorker do
  @moduledoc """
  Oban cron worker that flushes the audit log to every active SIEM export sink
  once a minute (`Barkpark.Audit.Export.flush/0`).

  `max_attempts: 1` because retry is inherent to the cursor model — a failed
  flush does not advance the sink's `last_exported_id`, so the next tick
  re-attempts the same events. No fencing is needed: `flush/0` only advances a
  cursor forward on a confirmed 2xx, and concurrent flushes of the same sink are
  idempotent (both read from the same high-water mark and advance to the same
  max id).
  """
  use Oban.Worker, queue: :default, max_attempts: 1

  alias Barkpark.Audit.Export

  @impl Oban.Worker
  def perform(_job) do
    Export.flush()
    :ok
  end
end
