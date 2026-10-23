defmodule Barkpark.Content.Workers.ScheduledPublishSweeper do
  @moduledoc """
  Retention for cancelled scheduled publishes (task-29663e18251a8b4c, split from task-44cfe871ea0edc30).

  Cancelling a schedule keeps its row (`cancelled`), and test cleanups cancel
  hundreds a week on a CI dataset, so `scheduled_publishes` grew without bound
  there. Daily, this deletes every `cancelled` row that ended more than
  `ScheduledPublishes.cancelled_ttl_days/0` ago (`:scheduled_publish_cancelled_ttl_days`).
  OFF by default: with that unset (`nil`) a tick deletes nothing, because how long
  Archived keeps history is the owner's decision. It never touches a pending,
  paused or finished one (see `ScheduledPublishes.purge_cancelled/1`).

  A cancelled row's Oban job, if it is still waiting, finds no row and does
  nothing (`ScheduledPublishes.run/1`). `args` may carry `"days"` to override the
  window (tests).
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Barkpark.Content.ScheduledPublishes

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days =
      case args do
        %{"days" => days} when is_integer(days) and days >= 0 -> days
        _ -> nil
      end

    {:ok, deleted} = ScheduledPublishes.purge_cancelled(days)

    if deleted > 0 do
      Logger.info("scheduled_publishes sweep deleted #{deleted} cancelled row(s)")
    end

    {:ok, %{deleted: deleted}}
  end
end
