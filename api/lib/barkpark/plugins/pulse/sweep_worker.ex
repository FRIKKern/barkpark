defmodule Barkpark.Pulse.SweepWorker do
  @moduledoc """
  Oban cron worker that TTL-sweeps `pulse_events` (the ephemeral feed) while
  leaving `pulse_counters` untouched (the durable total-ever). Scheduled by
  the pulse plugin's `oban_crontab/0`; with the plugin off it is never
  enqueued. Empty-config sweep returns `{:ok, %{}}` — never raises on
  "nothing to do".
  """

  use Oban.Worker, queue: :plugins, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    {:ok, Barkpark.Pulse.sweep()}
  end
end
