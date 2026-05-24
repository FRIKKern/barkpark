defmodule Barkpark.Search.Workers.Prune do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Barkpark.Search.Intelligence

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = Map.get(args, "retention_days", Intelligence.retention_days())
    {:ok, %{deleted: Intelligence.prune(retention_days: days)}}
  end
end
