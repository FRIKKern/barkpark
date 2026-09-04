defmodule Barkpark.Content.PaperAccess do
  @moduledoc """
  The paper view/edit trail — edit-on-the-link slice 4 (task-e99a8e946f80f52c).

  `revisions` records what CHANGED, and only when something did. Once a paper
  is a LINK you hand to somebody, the sharper question is the one revisions
  cannot answer: who has been on it at all. This module owns that answer.

  ## The contract

  `record/1` appends one `Barkpark.Content.PaperAccessLog` row and returns
  `:ok` NO MATTER WHAT. It is called from the reader's mount and from the edit
  path, and neither may fail because a log insert did. A rejected changeset, a
  dead connection, an unmigrated database — all of them log a warning and
  return `:ok`. The reader renders; the edit stands.

  That posture is the same one `Papers.BlockOps` already takes for
  `maybe_append_paper_event/3` and `maybe_save_batch_revision/3`: the content is
  the source of truth, and losing a trail entry is strictly better than losing
  the thing it describes.

  ## What is recorded

  One row per CONNECTED reader mount (`action: "view"`) and one per accepted
  block op (`action: "edit"`), carrying `BarkparkWeb.PaperActor`'s attribution
  triple. A dead render writes nothing: it is a crawler, an unfurler or the
  first half of a LiveView handshake, and counting it would make every social
  preview look like a reader.

  Anonymous access is recorded with `actor_kind: "anonymous"` and a NULL
  `actor_id` — counted, never identified.

  ## Retention

  `prune/1` deletes rows older than `ttl_days/0`
  (`config :barkpark, :paper_access_log_ttl_days`, default 90). Driven daily by
  `Barkpark.Content.Workers.PaperAccessSweeper`. The table is append-only in
  practice, not by trigger: unlike `audit_events` it is a retention-bounded
  operational trail, not a tamper-evident chain, and the sweeper needs DELETE.
  """

  import Ecto.Query

  require Logger

  alias Barkpark.Repo
  alias Barkpark.Content.PaperAccessLog

  @default_ttl_days 90
  @default_limit 100
  @max_limit 500

  @doc """
  Append one access row. ALWAYS returns `:ok` — see the moduledoc.

  `attrs` is a map carrying `:slug`, `:dataset`, `:action` and the actor triple
  (`:actor_kind`, `:actor_id`, `:actor_label`), plus an optional
  `:workspace_id`.
  """
  @spec record(map()) :: :ok
  def record(attrs) when is_map(attrs) do
    %PaperAccessLog{}
    |> PaperAccessLog.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("paper access log insert failed: #{inspect(reason)}")
        :ok
    end
  rescue
    # The reader must survive an unmigrated or unreachable database. A raised
    # DBConnection / Postgrex error here would take down a mount that has
    # nothing to do with logging.
    error ->
      Logger.warning("paper access log insert raised: #{inspect(error)}")
      :ok
  end

  def record(_attrs), do: :ok

  @doc """
  Build the `record/1` attrs for one access event from a paper identity and an
  actor. The single shape both call sites use, so a "view" row and an "edit"
  row can never disagree about their columns.
  """
  @spec entry(String.t(), String.t(), binary() | nil, String.t(), map()) :: map()
  def entry(slug, dataset, workspace_id, action, actor) when is_map(actor) do
    %{
      slug: slug,
      dataset: dataset,
      workspace_id: workspace_id,
      action: action,
      actor_kind: Map.get(actor, :kind) || "anonymous",
      actor_id: Map.get(actor, :id),
      actor_label: Map.get(actor, :label)
    }
  end

  @doc """
  List access rows for one paper, NEWEST FIRST.

  Scoped to `opts[:workspace_id]` when present. A nil workspace reads the rows
  that carry no workspace — the same NULL-tolerant posture the rest of Content
  takes, never "read every tenant's".

  `opts[:limit]` is clamped to #{@max_limit}; `opts[:dataset]` narrows further.
  """
  @spec list(String.t(), keyword()) :: [PaperAccessLog.t()]
  def list(slug, opts \\ []) when is_binary(slug) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    PaperAccessLog
    |> where([r], r.slug == ^slug)
    |> scope_workspace(Keyword.get(opts, :workspace_id))
    |> scope_dataset(Keyword.get(opts, :dataset))
    # `inserted_at` then `id`: two rows written in the same microsecond still
    # come back in a stable, insert-ordered sequence.
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Configured retention window in days (default #{@default_ttl_days})."
  @spec ttl_days() :: pos_integer()
  def ttl_days do
    case Application.get_env(:barkpark, :paper_access_log_ttl_days, @default_ttl_days) do
      days when is_integer(days) and days > 0 -> days
      _ -> @default_ttl_days
    end
  end

  @doc """
  Delete every row older than `ttl_days/0`. Returns `{:ok, deleted_count}`.

  `days` may be passed explicitly (tests pass 0 to make the sweep
  deterministic).
  """
  @spec prune(pos_integer() | non_neg_integer() | nil) :: {:ok, non_neg_integer()}
  def prune(days \\ nil) do
    days = if is_integer(days) and days >= 0, do: days, else: ttl_days()
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {deleted, _} =
      PaperAccessLog
      |> where([r], r.inserted_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, deleted}
  end

  defp scope_workspace(query, ws) when is_binary(ws), do: where(query, [r], r.workspace_id == ^ws)
  defp scope_workspace(query, _ws), do: where(query, [r], is_nil(r.workspace_id))

  defp scope_dataset(query, ds) when is_binary(ds) and ds != "",
    do: where(query, [r], r.dataset == ^ds)

  defp scope_dataset(query, _ds), do: query

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_limit), do: @default_limit
end
