defmodule Barkpark.Sync.Outbox do
  @moduledoc """
  Read-only window over the LOCAL `mutation_events` table that feeds the push
  loop. The single place echo-suppression (invariant #4) is enforced on the
  read side: any event stamped `source = "sync"` (a PULL-applied write) is
  EXCLUDED, so a mutation that arrived via pull is never pushed back — no
  ping-pong.

  `type = "listener"` events are likewise EXCLUDED: Personal Dev Fleet listener
  presence is per-machine truth (a heartbeat that only makes sense on the host
  it describes), so it must never fan out to synced remotes. Mirroring the
  echo-suppression idiom, the filter lives in the read-side where-clause.

  This module does READS ONLY (a plain `Repo` query — never a write through
  `content.ex`/`tasks.ex`), so invariant #1 holds. Events come back in
  `id ASC` order (causal replay) and `after_id` is the push cursor, so the loop
  fetches strictly `id > cursor`.
  """

  import Ecto.Query

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo

  @doc """
  Fetch up to `limit` un-pushed, non-sync-originated, non-`listener` events for
  `dataset`, with `id > after_id`, in `id ASC` order. `after_id` is the push
  cursor; `limit` is `push_batch_size`.
  """
  #
  # `workspace_id` is the configured LOCAL workspace the push serves
  # (`Sync.push_context/1`). Every workspace owns a dataset with the same
  # string, so without it the outbox read every workspace's events and the
  # push sent other tenants' document bodies to this workspace's remote
  # (task-43b484660f68075d). A nil workspace keeps the old dataset-only read.
  @spec fetch(String.t(), non_neg_integer(), pos_integer(), binary() | nil) ::
          [MutationEvent.t()]
  def fetch(dataset, after_id, limit, workspace_id \\ nil)
      when is_binary(dataset) and is_integer(after_id) and after_id >= 0 and is_integer(limit) and
             limit > 0 do
    from(e in MutationEvent,
      where:
        e.dataset == ^dataset and e.id > ^after_id and
          (is_nil(e.source) or e.source != "sync") and
          e.type != "listener",
      order_by: [asc: e.id],
      limit: ^limit
    )
    |> maybe_scope_workspace(workspace_id)
    |> Repo.all()
  end

  defp maybe_scope_workspace(query, ws) when is_binary(ws) and ws != "",
    do: where(query, [e], e.workspace_id == ^ws)

  defp maybe_scope_workspace(query, _ws), do: query
end
