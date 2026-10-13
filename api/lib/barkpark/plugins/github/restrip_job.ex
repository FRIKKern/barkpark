defmodule Barkpark.Plugins.Github.RestripJob do
  @moduledoc """
  One issue's share of the restrip (owner ruling #11, see
  `Barkpark.Plugins.Github.Restrip`): re-run the ordinary mirror reconcile
  for one task with `restrip: true`, so an already-synced task is PATCHed to
  its stripped body.

  A separate worker on the same `:github_mirror` queue, deliberately: a
  restrip job is scheduled minutes or hours out, and sharing `MirrorJob`'s
  `{doc_id, dataset}` uniqueness would make a real edit in that window
  coalesce into the far-future job and stall the task's normal mirror.
  """

  use Oban.Worker,
    queue: :github_mirror,
    max_attempts: 5,
    unique: [
      keys: [:doc_id, :dataset],
      states: [:available, :scheduled, :executing],
      period: 3600
    ]

  alias Barkpark.Plugins.Github.MirrorJob

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"doc_id" => doc_id, "dataset" => dataset}}) do
    MirrorJob.reconcile(doc_id, dataset, restrip: true)
  end
end
