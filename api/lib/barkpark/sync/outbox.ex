defmodule Barkpark.Sync.Outbox do
  @moduledoc """
  Read-only window over the LOCAL `mutation_events` table that feeds the push
  loop. The single place echo-suppression (invariant #4) is enforced on the
  read side: any event stamped `source = "sync"` (a PULL-applied write) is
  EXCLUDED, so a mutation that arrived via pull is never pushed back — no
  ping-pong.

  This module does READS ONLY (a plain `Repo` query — never a write through
  `content.ex`/`tasks.ex`), so invariant #1 holds. Events come back in
  `id ASC` order (causal replay) and `after_id` is the push cursor, so the loop
  fetches strictly `id > cursor`.
  """

  import Ecto.Query

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo

  @doc """
  Fetch up to `limit` un-pushed, non-sync-originated events for `dataset`,
  with `id > after_id`, in `id ASC` order. `after_id` is the push cursor;
  `limit` is `push_batch_size`.
  """
  @spec fetch(String.t(), non_neg_integer(), pos_integer()) :: [MutationEvent.t()]
  def fetch(dataset, after_id, limit)
      when is_binary(dataset) and is_integer(after_id) and after_id >= 0 and is_integer(limit) and
             limit > 0 do
    from(e in MutationEvent,
      where:
        e.dataset == ^dataset and e.id > ^after_id and
          (is_nil(e.source) or e.source != "sync"),
      order_by: [asc: e.id],
      limit: ^limit
    )
    |> Repo.all()
  end
end
