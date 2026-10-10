defmodule Barkpark.Content.Workers.ScheduledPublishWorker do
  @moduledoc """
  Fires one scheduled publish at its `publish_at` (task-8e88b5539acafdae).

  The job carries only the schedule id. `Barkpark.Content.ScheduledPublishes.run/1`
  re-reads the row and acts only while it is still `scheduled`, so a cancelled
  schedule's job finishes as a no-op. A refusal or a failed publish is a
  FINISHED schedule (recorded on the row), not a job error, so it is never
  retried into a later publish nobody asked for.
  """
  # One live job per schedule: `ScheduledPublishes.rearm/1` may enqueue for a
  # row whose job already exists (a merge import onto a live instance).
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      keys: [:id],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Barkpark.Content.ScheduledPublishes

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) when is_binary(id) do
    {:ok, _} = ScheduledPublishes.run(id)
    :ok
  end

  def perform(_job), do: {:cancel, :missing_schedule_id}
end
