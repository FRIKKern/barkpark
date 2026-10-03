defmodule Barkpark.StudioChat.ManagedSessionTarget do
  @moduledoc """
  The "open session" target for a workflow agent's task (task
  wsc-steer-open-session-managed, steer paper wsc-steer-fleet-design §3 and §5).

  Only one lane has a real session behind a builder: the CycleFleet MANAGED
  Codex lane. `epic_assignment_runtime_attempts` binds each managed assignment
  to exactly one `chat_sessions` row (unique, NOT NULL, CHECK-locked to
  `provider = 'codex'` and `execution_target = 'managed'`). A Claude-lane
  builder is a Task-tool subagent with no session at all, so it has no row
  here and resolves to `:none`. The surfaces then render NO session control,
  not a disabled one (the dead-affordance law).

  `resolve/2` answers for one task, by the task's doc id (the id the agent↔task
  join, `Barkpark.StudioChat.AgentTaskJoin`, hands back). It returns
  `{:ok, target}` only when exactly one LIVE attempt names the task:

    * no attempt for the task (Claude lane, or a task CycleFleet never ran) →
      `:none`;
    * an attempt whose frozen claim is no longer the task's live claim
      (released, re-claimed, a newer epoch: `CycleFleet.current_runtime_attempt_attribution/1`
      refuses it) is STALE → it does not count;
    * more than one live attempt → AMBIGUOUS → `:none`, never a best guess;
    * the bound session is missing or outside `:scope` → `:none`.

  The read is two indexed queries and never raises: any lookup failure is
  `:none`, which renders exactly like the Claude lane.
  """

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet
  alias Barkpark.CycleFleet.RuntimeAttempt
  alias Barkpark.Repo
  alias Barkpark.StudioChat

  @type target :: %{session_id: String.t(), assignment_id: String.t(), task_doc_id: String.t()}

  @doc """
  Resolve the managed session behind `task_doc_id`.

  Options:

    * `:scope` — the chat store scope the session must be visible in
      (`:global` or a workspace id, as `StudioChat.get_session/2` takes it).
      Defaults to `:global`; callers with a narrower tenancy pass theirs.
  """
  @spec resolve(String.t() | nil, keyword()) :: {:ok, target()} | :none
  def resolve(task_doc_id, opts \\ [])

  def resolve(task_doc_id, opts) when is_binary(task_doc_id) do
    bare = String.replace_prefix(String.trim(task_doc_id), "drafts.", "")

    if bare == "" do
      :none
    else
      do_resolve(bare, Keyword.get(opts, :scope, :global))
    end
  rescue
    _ -> :none
  end

  def resolve(_task_doc_id, _opts), do: :none

  defp do_resolve(bare, scope) do
    with [_ | _] = row_ids <- task_row_ids(bare),
         [attempt] <- live_attempts(row_ids),
         %StudioChat.Session{id: session_id} <- StudioChat.get_session(attempt.session_id, scope) do
      {:ok, %{session_id: session_id, assignment_id: attempt.assignment_id, task_doc_id: bare}}
    else
      _ -> :none
    end
  end

  # The published row and its draft twin are one task; an attempt may have been
  # frozen against either row id.
  defp task_row_ids(bare) do
    Repo.all(
      from(d in Document,
        where: d.type == "task" and d.doc_id in ^[bare, "drafts." <> bare],
        select: d.id
      )
    )
  end

  defp live_attempts(row_ids) do
    from(a in RuntimeAttempt,
      where: a.task_id in ^row_ids and a.provider == "codex" and a.execution_target == "managed"
    )
    |> Repo.all()
    |> Enum.filter(&match?({:ok, _}, CycleFleet.current_runtime_attempt_attribution(&1)))
  end
end
