defmodule Barkpark.Workers.SearchAnalyticsCrystallize do
  @moduledoc false
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Barkpark.Search.Workers.Crystallize, as: Core

  @impl Oban.Worker
  def perform(job), do: Core.perform(job)
end
