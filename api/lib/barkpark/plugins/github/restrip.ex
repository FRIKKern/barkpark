defmodule Barkpark.Plugins.Github.Restrip do
  @moduledoc """
  Re-PATCH issues mirrored before the body strip (owner ruling #11,
  2026-10-03, task `github-bridge-mirror-exposure-decision`).

  `Projection` publishes a task's brief only for an allow-listed task (an
  adopted `gh-<num>` intake row, or one labelled `public`). Issues mirrored
  earlier still carry the internal brief, and most of their tasks are dormant,
  so the ordinary mirror (which only runs when a task's rev moves) would never
  rewrite them. This walks every published, mirrored task and:

    * `plan/2` — READ-ONLY. Counts the mirrored tasks and how many issue bodies
      the strip changes (a non-empty brief on a task that is not allow-listed).
      No GitHub call, no write.
    * `enqueue/2` — inserts one `RestripJob` per changed task, spaced
      `interval_seconds` apart so the mass edit stays under GitHub's secondary
      rate limit. Each job runs the ordinary `MirrorJob.reconcile/3` with
      `restrip: true` (the synced-rev short-circuit is skipped), so it goes
      through the existing mirror credential, the drift record and the
      fingerprint stamp exactly like any other mirror write.

  A task counts as mirrored when its published row carries `content.github`
  with an integer `issue` and a state other than `detached` / `intake`.
  """

  alias Barkpark.Content
  alias Barkpark.Plugins.Github.{Link, Projection, RestripJob}

  @task_type "task"

  @typedoc "What a restrip would do, per dataset."
  @type plan :: %{
          dataset: String.t(),
          mirrored: non_neg_integer(),
          would_change: non_neg_integer(),
          allowlisted: non_neg_integer(),
          unchanged: non_neg_integer(),
          truncated: boolean(),
          changed_ids: [String.t()]
        }

  @doc "Count what a restrip of `dataset` would change. Read-only."
  @spec plan(String.t(), keyword()) :: plan()
  def plan(dataset \\ "production", opts \\ []) when is_binary(dataset) do
    {docs, truncated} = mirrored_tasks(dataset, opts)

    {changed, allowlisted, unchanged} =
      Enum.reduce(docs, {[], 0, 0}, fn doc, {ch, al, un} ->
        content = doc.content || %{}

        cond do
          Projection.public_brief?(content, doc.doc_id) -> {ch, al + 1, un}
          brief?(content) -> {[doc.doc_id | ch], al, un}
          true -> {ch, al, un + 1}
        end
      end)

    changed = Enum.reverse(changed)

    %{
      dataset: dataset,
      mirrored: length(docs),
      would_change: length(changed),
      allowlisted: allowlisted,
      unchanged: unchanged,
      truncated: truncated == :cap,
      changed_ids: changed
    }
  end

  @doc """
  Insert one spaced `RestripJob` per task `plan/2` reports as changing.
  Returns `{:ok, inserted_count}`. `:interval_seconds` (default 2) spaces
  the jobs; `:limit` caps how many are inserted in this call.
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, non_neg_integer()}
  def enqueue(dataset \\ "production", opts \\ []) when is_binary(dataset) do
    interval = Keyword.get(opts, :interval_seconds, 2) |> max(1)
    %{changed_ids: ids} = plan(dataset, opts)

    ids =
      case Keyword.get(opts, :limit) do
        n when is_integer(n) and n > 0 -> Enum.take(ids, n)
        _ -> ids
      end

    inserted =
      ids
      |> Enum.with_index()
      |> Enum.count(fn {doc_id, i} ->
        match?(
          {:ok, _},
          %{"doc_id" => doc_id, "dataset" => dataset}
          |> RestripJob.new(schedule_in: i * interval)
          |> insert_job()
        )
      end)

    {:ok, inserted}
  end

  # The mix task runs in a one-shot boot with no Oban supervisor (it must not
  # start a second Oban draining the live queues), so there the job row is
  # written straight to `oban_jobs` and the live app's Oban stages it. Inside a
  # running app (and in tests) the ordinary `Oban.insert/1` is used.
  defp insert_job(changeset) do
    if Oban.whereis(Oban), do: Oban.insert(changeset), else: Barkpark.Repo.insert(changeset)
  end

  defp mirrored_tasks(dataset, opts) do
    read_opts =
      [perspective: :published, filter_map: %{"github.issue" => %{"is" => "notnull"}}]
      |> Keyword.merge(Keyword.take(opts, [:workspace_id, :project_id]))

    {docs, truncated} = Content.collect_all_documents(@task_type, dataset, read_opts)

    {Enum.filter(docs, &live_link?/1), truncated}
  end

  defp live_link?(doc) do
    case Link.get(doc) do
      %{"issue" => n} = link when is_integer(n) ->
        Map.get(link, "state") not in ["detached", "intake"]

      _ ->
        false
    end
  end

  defp brief?(content) do
    case Map.get(content, "description") do
      d when is_binary(d) -> String.trim(d) != ""
      _ -> false
    end
  end
end
