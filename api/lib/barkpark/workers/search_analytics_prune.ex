defmodule Barkpark.Workers.SearchAnalyticsPrune do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Barkpark.Search.Workers.Prune, as: Core

  @impl Oban.Worker
  def perform(job), do: Core.perform(job)
end
