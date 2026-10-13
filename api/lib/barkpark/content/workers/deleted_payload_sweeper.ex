defmodule Barkpark.Content.Workers.DeletedPayloadSweeper do
  @moduledoc """
  Daily retention sweep for copies of deleted content in `mutation_events` and
  `webhook_deliveries` — owner ruling #33 (2026-10-03, task-43179d8d03efe969).
  The policy, and why payloads are redacted rather than rows deleted, lives in
  `Barkpark.Content.DeletedPayloadRetention`.

  SHIPS DISABLED. While `config :barkpark, :deleted_payload_retention,
  enabled: false` (the default; runtime switch
  `BARKPARK_DELETED_PAYLOAD_RETENTION=on`) a tick writes nothing and returns
  `{:ok, %{skipped: :disabled}}`.

  Scheduled at 04:30, after the 04:00 search prune and the 04:15 paper
  access-log sweep, so the range scans never open in the same tick. A backlog
  larger than one tick's bounded passes finishes on the next day's run.

  `args` may carry `"days"` to override the window (tests).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.Content.DeletedPayloadRetention

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if DeletedPayloadRetention.enabled?() do
      {:ok, result} = DeletedPayloadRetention.sweep(override(args))

      if result.mutation_events + result.webhook_deliveries > 0 do
        Logger.info(
          "deleted_payload_retention redacted #{result.mutation_events} mutation_events " <>
            "and #{result.webhook_deliveries} webhook_deliveries payload(s)"
        )
      end

      {:ok, result}
    else
      {:ok, %{skipped: :disabled}}
    end
  end

  defp override(%{"days" => days}) when is_integer(days) and days >= 0, do: [days: days]
  defp override(_args), do: []
end
