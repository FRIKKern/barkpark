defmodule Barkpark.Search.Workers.Crystallize do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Barkpark.Search.Crystallizer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    date =
      case Map.get(args, "date") do
        nil -> Date.utc_today()
        iso when is_binary(iso) -> Date.from_iso8601!(iso)
      end

    {:ok, Crystallizer.crystallize_due(date)}
  end
end
