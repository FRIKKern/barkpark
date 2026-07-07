defmodule Barkpark.Plugins.Github.Outbox do
  @moduledoc """
  Read-only window over the LOCAL `mutation_events` table that feeds the OUTBOUND
  GitHub mirror. This is the reader half of the at-least-once source (epic D1/D2):
  the wave-2 drain worker fetches `id > cursor` here and enqueues a debounced
  per-task MirrorJob for each row.

  Two filters shape the window beyond `id > after_id`:

  1. `type == "task"` — only TASK mutations mirror to GitHub Issues. Repo issues
     map to TASKS, never the Tickets plugin (epic D6).
  2. `source != "github"` — LOOP-CUT #2 (epic D4). Inbound-applied writes (a
     GitHub-originated issue intaken by wave 3) are stamped `source: :github`
     (`save_event` does `to_string(source)`), so they must NEVER be mirrored back
     out. This is the exact proven pattern `Barkpark.Sync.Outbox` uses to exclude
     `source = "sync"` (pull-applied) rows. A `NULL` source (defensive) is treated
     as local-origin and included.

  This module does READS ONLY (a plain `Repo` query — never a write through
  `content.ex`/`tasks.ex`). Events come back in `id ASC` order (causal replay) and
  `after_id` is the outbound cursor, so the loop fetches strictly `id > cursor`.
  """

  import Ecto.Query

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo

  @doc """
  Fetch up to `limit` un-mirrored, non-github-originated TASK events for
  `dataset`, with `id > after_id`, in `id ASC` order. `after_id` is the outbound
  cursor; `limit` bounds the drain batch.

  Excludes `source = "github"` rows (loop-cut #2) and any non-task rows.
  """
  @spec fetch(String.t(), non_neg_integer(), pos_integer()) :: [MutationEvent.t()]
  def fetch(dataset, after_id, limit)
      when is_binary(dataset) and is_integer(after_id) and after_id >= 0 and is_integer(limit) and
             limit > 0 do
    from(e in MutationEvent,
      where:
        e.dataset == ^dataset and e.id > ^after_id and e.type == "task" and
          (is_nil(e.source) or e.source != "github"),
      order_by: [asc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end
end
