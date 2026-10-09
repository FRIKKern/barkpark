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

  ## Unset intake workspace: instance-wide by design, not a bug (ruling #12)

  Owner ruling #12 (task-803343b8cce8bfb7, shipped PR #21556) confirmed that
  with `BARKPARK_GITHUB_INTAKE_WORKSPACE_ID` unset, `fetch/3` returns every
  workspace's task events — "unset keeps today's instance-wide window, so a
  single-workspace install sees no change." This is a DELIBERATE default, not
  a hole to close silently: flipping it to fail-closed would regress every
  currently-working single-tenant install that has never needed to set the
  var. That ruling stands.

  What IS new here: a one-time `Logger.warning` (zero behaviour change — the
  query is unaffected) when the var is unset AND the dataset being drained
  already holds task events from more than one workspace. That is exactly the
  scenario
  ruling #12's own "OPEN QUESTION" flagged and left for a human to notice later
  ("the public mirror exposes the whole internal backlog... confirm
  public-roadmap intent"): a single-workspace install never triggers it, and a
  multi-tenant one now gets told once, in the server log, instead of silently
  leaking workspace B's task titles into workspace A's operator's repo.
  """

  import Ecto.Query
  require Logger

  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.Settings
  alias Barkpark.Repo

  # persistent_term flag so the multi-workspace warning fires at most once per
  # process lifetime once it has fired — never spammed once-per-tick. It is
  # NOT set on a negative check (still only one workspace), so a later
  # transition to a second workspace is still caught on its first tick after.
  @multi_workspace_warned_key {__MODULE__, :multi_workspace_warned}

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
    |> scope_to_intake_workspace(Settings.intake_workspace_id(), dataset)
    |> Repo.all()
  end

  # Owner ruling #12 (task-803343b8cce8bfb7): with
  # `BARKPARK_GITHUB_INTAKE_WORKSPACE_ID` set, only THAT workspace's tasks
  # mirror out — the same workspace inbound intake writes into. On a box with
  # several workspaces every workspace's tasks used to land in the one repo.
  # Unset keeps today's instance-wide window, so a single-workspace install
  # sees no change. The cursor still advances past filtered-out events
  # (`DrainWorker` moves it to the last FETCHED id, and a filtered event is
  # simply never fetched), so nothing piles up.
  defp scope_to_intake_workspace(query, nil, dataset) do
    maybe_warn_multi_workspace(dataset)
    query
  end

  defp scope_to_intake_workspace(query, workspace_id, _dataset) when is_binary(workspace_id),
    do: from(e in query, where: e.workspace_id == ^workspace_id)

  # Fires at most once per process lifetime. Cheap on the common (single-
  # workspace, or already-warned) path: a `persistent_term` read, then — only
  # while unwarned — one small `SELECT DISTINCT ... LIMIT 2` scoped to the
  # dataset actually being drained right now.
  defp maybe_warn_multi_workspace(dataset) do
    unless already_warned?() do
      if multi_workspace_tasks?(dataset) do
        Logger.warning(
          "github outbox: task events from more than one workspace are present in dataset " <>
            "#{inspect(dataset)}, and BARKPARK_GITHUB_INTAKE_WORKSPACE_ID is unset -- every " <>
            "workspace's tasks are being mirrored into the single configured repo. This is " <>
            "ruling #12's accepted default (task-803343b8cce8bfb7: unset keeps the " <>
            "instance-wide mirror, by design, for single-tenant installs) and behaviour is " <>
            "UNCHANGED. If this instance is multi-tenant and that is not intended, set " <>
            "BARKPARK_GITHUB_INTAKE_WORKSPACE_ID to scope the mirror to one workspace. This " <>
            "warning fires once per boot."
        )

        :persistent_term.put(@multi_workspace_warned_key, true)
      end
    end

    :ok
  end

  defp already_warned?, do: :persistent_term.get(@multi_workspace_warned_key, false)

  defp multi_workspace_tasks?(dataset) do
    from(e in MutationEvent,
      where:
        e.type == "task" and e.dataset == ^dataset and
          (is_nil(e.source) or e.source != "github"),
      distinct: true,
      select: e.workspace_id,
      limit: 2
    )
    |> Repo.all()
    |> length() > 1
  end

  @doc false
  # Test seam: clear the one-time warning flag so each test starts unwarned.
  # `:persistent_term.erase/1` returns `false` (not an error) on a missing key.
  @spec reset_multi_workspace_warning() :: :ok
  def reset_multi_workspace_warning do
    :persistent_term.erase(@multi_workspace_warned_key)
    :ok
  end
end
