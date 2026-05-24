defmodule Barkpark.Workers.SearchAnalyticsCrystallize do
  @moduledoc """
  Nightly crystallization of search analytics into day / week / month rollups.

  Runs before raw-event pruning so aggregates survive the 90-day retention window.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Barkpark.Media.SearchCrystallizer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    date =
      case Map.get(args, "date") do
        nil -> Date.utc_today()
        iso when is_binary(iso) -> Date.from_iso8601!(iso)
      end

    stats = SearchCrystallizer.crystallize_due(date)
    {:ok, stats}
  end
end
