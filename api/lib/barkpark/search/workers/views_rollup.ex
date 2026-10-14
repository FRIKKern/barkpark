defmodule Barkpark.Search.Workers.ViewsRollup do
  @moduledoc """
  Rewrites `document_popularity` from `document_view_days` and prunes old
  day rows (`Barkpark.Search.Views.rollup/1`). Oban cron, every 10 minutes
  (`config/config.exs`). It flushes the view buffer first, so a rollup
  includes views recorded up to the moment it runs.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Barkpark.Search.Views

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Views.flush()
    {:ok, Views.rollup()}
  end
end
