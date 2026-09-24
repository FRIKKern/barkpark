defmodule Barkpark.Plugins.Github.RetireJob do
  @moduledoc """
  Closes the mirror Issue of a task that was HARD-DELETED
  (spd-b45-deleted-task-orphans-github-mirror).

  ## The orphan this closes

  `MirrorJob` already retracts a withdrawn promise on the UNPUBLISH path: the
  publish gate's `retract/4` arm closes the issue `not_planned` when a
  previously-mirrored task loses its published row. That arm works because
  `Lifecycle.unpublish_document/4` COPIES `content.github` onto the surviving
  draft — the issue number is still readable.

  A hard delete has no surviving row. `Lifecycle.delete_document/4` removes the
  published AND the draft variant, so the next reconcile's `load_task/3` returns
  `nil` and the job cancels `:task_gone` — holding nothing it could close. The
  issue stays OPEN forever, its body naming a task id that answers not_found.
  Five were found and closed by hand on 2026-07/08 (#2355 #2356 #2357 #2358
  #2516); four of them were minted within 16 seconds by one probe session and
  sat open for ten days.

  ## Why a hook and not a reconciler

  The issue number is knowable at exactly ONE moment: while the document still
  exists. `Barkpark.Plugins.Github.lifecycle_hooks/0` registers
  `enqueue_for_deleted/1` on `:after_delete`, which fires post-commit with the
  just-deleted document in `payload.doc` — the last reader of
  `content.github.issue`. It reads the number, and ENQUEUES this job rather
  than calling GitHub inline: `after_delete` hooks run under a 5s
  `Task.async_stream` timeout whose return value is discarded, so an inline HTTP
  close would be killed mid-flight by a slow GitHub and recreate the very orphan
  it was added to prevent. An Oban job is durable, retried and rate-limit aware.

  This stops NEW orphans by construction. It does not clean history — a delete
  that already happened left no record of its issue number anywhere in Barkpark.
  Those are swept by hand off the open-issue list (criterion 2 of the row).

  ## What it refuses to touch

    * `state: "detached"` — the issue was deleted or transferred out of band
      (D7). We never recreate it and never PATCH it.
    * `state: "intake"` — a born-dark inbound `gh-<num>` awaiting adoption
      (D13). It carries an OUTSIDER's issue number and no consent to write.
      Deleting the un-adopted Barkpark shadow must not close their issue.
    * no integer `content.github.issue` — never mirrored, nothing is stranded.
    * a non-`task` document — only tasks mirror to Issues (D6).

  ## The re-check

  `perform/1` re-reads the doc_id before it closes. A delete followed by a
  re-create (same id) inside the job's queue latency would otherwise close the
  issue of a LIVE task. Either variant existing is enough to abort: the job
  exists to retire an issue whose task is GONE, and "gone" is a property of the
  present, not of the event that enqueued it.
  """

  use Oban.Worker,
    queue: :github_mirror,
    max_attempts: 5,
    unique: [
      keys: [:doc_id, :dataset, :issue],
      states: [:available, :scheduled, :executing],
      period: 60
    ]

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Github.{Client, Link}

  alias Barkpark.Plugins.Github.Errors.{
    AuthError,
    NetworkError,
    NotFound,
    RateLimitError
  }

  @task_type "task"

  @doc """
  The `:after_delete` lifecycle hook. Reads the just-deleted document's mirror
  bookkeeping and enqueues a close for its issue.

  Returns `:ok` in every case — an `after_delete` hook's return value is
  discarded and it must never disturb a write that has already committed.
  """
  @spec enqueue_for_deleted(map()) :: :ok
  def enqueue_for_deleted(%{doc: doc, dataset: dataset})
      when is_map(doc) and is_binary(dataset) do
    with true <- task?(doc),
         link when is_map(link) <- Link.get(doc),
         num when is_integer(num) <- Map.get(link, "issue"),
         :ok <- mirrorable_state(Map.get(link, "state")),
         repo when is_binary(repo) and repo != "" <- repo_for(link) do
      %{
        doc_id: Content.published_id(doc_id_of(doc)),
        dataset: dataset,
        repo: repo,
        issue: num
      }
      |> Map.merge(scope_args(doc))
      |> new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "github retire: could not enqueue close of issue ##{num} for deleted " <>
              "task #{inspect(doc_id_of(doc))}: #{inspect(reason)}"
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  def enqueue_for_deleted(_payload), do: :ok

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"doc_id" => doc_id, "dataset" => dataset, "repo" => repo, "issue" => num} = args
      })
      when is_binary(repo) and is_integer(num) do
    opts = scope_opts(args)

    if task_present?(doc_id, dataset, opts) do
      # The id came back between the delete and this run. Retiring the mirror of
      # a LIVE task would be worse than the orphan.
      {:cancel, :task_returned}
    else
      close(repo, num, opts)
    end
  end

  defp close(repo, num, opts) do
    case Client.close_issue(repo, num, :not_planned, opts) do
      {:ok, _issue} ->
        :ok

      {:error, %RateLimitError{retry_after: s}} ->
        {:snooze, max(s || 1, 1)}

      {:error, %NotFound{}} ->
        # The issue is already gone (deleted or transferred). Nothing stranded.
        {:cancel, :issue_gone}

      {:error, %NetworkError{reason: {:http, status}}} when status >= 400 and status < 500 ->
        # Permanent (422/validation, 403 on an archived repo). Dead-letter it
        # rather than retry forever — the same shape MirrorJob.classify/7 uses.
        {:cancel, {:client_error, status}}

      {:error, %AuthError{} = err} ->
        {:error, err}

      {:error, err} ->
        {:error, err}
    end
  end

  # ─── Helpers ───────────────────────────────────────────────────────────────

  defp task_present?(doc_id, dataset, opts) do
    published = Content.published_id(doc_id)

    Enum.any?([published, Content.draft_id(published)], fn id ->
      match?({:ok, %Document{}}, Content.get_document(id, @task_type, dataset, opts))
    end)
  end

  defp task?(%Document{type: type}), do: type == @task_type
  defp task?(%{type: type}), do: type == @task_type
  defp task?(%{"type" => type}), do: type == @task_type
  defp task?(_), do: false

  defp doc_id_of(%Document{doc_id: id}), do: id
  defp doc_id_of(%{doc_id: id}) when is_binary(id), do: id
  defp doc_id_of(%{"doc_id" => id}) when is_binary(id), do: id

  # A link we are allowed to close. Fail-CLOSED on anything unrecognised: a
  # state string this module has never seen is not a licence to PATCH someone's
  # issue. `nil` (a pre-state link, stamped before the field existed) IS ours —
  # it can only have come from our own create path.
  defp mirrorable_state(state) when state in [nil, "synced", "adopted"], do: :ok
  defp mirrorable_state(_), do: :skip

  # The repo the issue actually LIVES in, off the link, falling back to the
  # currently-configured mirror repo. A task stamped against an older repo must
  # be retired where its issue is, never where the config now points.
  defp repo_for(link) do
    case Map.get(link, "repo") do
      r when is_binary(r) and r != "" -> r
      _ -> Barkpark.Plugins.Github.Settings.repo()
    end
  end

  # TENANT SCOPE off the DELETED ROW ITSELF, not off `ctx` (which carries only
  # `source`/`user_id`). The job re-reads the doc_id to confirm it is still
  # gone, and an unscoped read of a task living in a non-default workspace
  # would not find it — it would look absent and the close would proceed for
  # the wrong reason. Absent columns (a pre-tenancy row) → default scope, the
  # same back-compatible shape `MirrorJob.scope_opts/1` degrades to.
  defp scope_args(doc) do
    %{}
    |> put_present(:workspace_id, field(doc, :workspace_id))
    |> put_present(:project_id, field(doc, :project_id))
  end

  defp field(%Document{} = doc, key), do: Map.get(doc, key)
  defp field(doc, key) when is_map(doc), do: Map.get(doc, key) || Map.get(doc, to_string(key))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp scope_opts(args) when is_map(args) do
    []
    |> put_opt(:workspace_id, Map.get(args, "workspace_id"))
    |> put_opt(:project_id, Map.get(args, "project_id"))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
