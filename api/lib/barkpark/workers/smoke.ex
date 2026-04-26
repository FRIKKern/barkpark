defmodule Barkpark.Workers.Smoke do
  @moduledoc """
  Oban smoke-test worker. Lets us verify queue + executor + telemetry wiring
  end-to-end without depending on a real plugin job.

  `perform(%Oban.Job{args: %{"echo" => msg}})` returns `{:ok, msg}`.
  Any other args succeed with `:ok`.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"echo" => msg}}), do: {:ok, msg}
  def perform(%Oban.Job{}), do: :ok
end
