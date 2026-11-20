defmodule Barkpark.Content.Papers.SavedCheck do
  @moduledoc """
  A caller's check of a Paper as saved, run inside the write's transaction.

  The check rides the write's opts as `before_commit:`, a 1-arity function
  handed the row the write saved (`%Document{}`) that answers `:ok` or
  `{:error, reason}`. Inside the transaction it reads that row as written. On `{:error, reason}`
  the write rolls back and answers that error: the row, its rev, its cache and
  its history row stay as they were, and the effects a write runs after its
  commit (broadcasts, the edge projection, change events) never run. A write
  without the option is unchanged.

  Before the caller's check, the saved row's scope is checked, failing closed:
  its project must belong to its workspace (`scope_unowned`), and the write's
  `may_write:` predicate, given the saved row's workspace id, must answer
  `true` (`write_forbidden`). The caller builds it from the writing token's
  own write rule; a write with none (the shared-secret producer) has only the
  first check.
  """

  alias Barkpark.Content.{Broadcast, Document}
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @doc """
  A block-op batch's persist (`{:ok, receipt, effects}` or `{:error, _}`) of
  the row `doc`, run with the check before it commits. The check is handed
  the saved row, or `doc` itself when the batch wrote nothing. The
  transaction owns the deferred broadcast queue
  (`Broadcast.with_deferred_queue/1`), so anything the persist queues is sent
  on commit and dropped on a refusal.
  """
  @spec batch(keyword(), Document.t(), (-> {:ok, term(), term()} | {:error, term()})) ::
          {:ok, term(), term()} | {:error, term()}
  def batch(opts, %Document{} = doc, persist) when is_function(persist, 0) do
    case Keyword.get(opts, :before_commit) do
      nil ->
        persist.()

      check when is_function(check, 1) ->
        Broadcast.with_deferred_queue(fn ->
          Repo.transaction(fn ->
            with {:ok, receipt, effects} <- persist.(),
                 saved = saved_row(effects, doc),
                 :ok <- scope_check(saved, Keyword.get(opts, :may_write)),
                 :ok <- check.(saved) do
              {receipt, effects}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        end)
        |> case do
          {:ok, {receipt, effects}} -> {:ok, receipt, effects}
          {:error, _reason} = refused -> refused
        end
    end
  end

  @doc "The check of the saved row `doc`, in the write's open transaction; `:ok` without one."
  @spec run(keyword(), Document.t()) :: :ok | {:error, term()}
  def run(opts, %Document{} = doc) do
    case Keyword.get(opts, :before_commit) do
      nil ->
        :ok

      check when is_function(check, 1) ->
        with :ok <- scope_check(doc, Keyword.get(opts, :may_write)), do: check.(doc)
    end
  end

  @doc "The saved row's scope check alone (see the moduledoc)."
  @spec scope_check(Document.t(), (binary() | nil -> boolean()) | nil) ::
          :ok | {:error, {:view_refused, map()}}
  def scope_check(%Document{} = row, may_write) do
    cond do
      not owned_pair?(row) ->
        refuse(
          "scope_unowned",
          "the Paper would be stored under a project that is not one of its workspace's"
        )

      not may_write?(may_write, row.workspace_id) ->
        refuse(
          "write_forbidden",
          "the Paper would be stored in a workspace this token may not write in"
        )

      true ->
        :ok
    end
  end

  defp owned_pair?(%Document{project_id: nil}), do: true

  defp owned_pair?(%Document{workspace_id: ws_id, project_id: project_id}) do
    match?(%{workspace_id: ^ws_id}, Tenancy.get_project_by_id(project_id)) and is_binary(ws_id)
  end

  defp may_write?(nil, _ws_id), do: true
  defp may_write?(check, ws_id) when is_function(check, 1), do: check.(ws_id) == true
  defp may_write?(_check, _ws_id), do: false

  defp refuse(code, message) do
    body = %{
      code: code,
      message: message <> ", so nothing was written",
      hint: "write with a token seated in the Paper's workspace, under one of its projects"
    }

    {:error, {:view_refused, body}}
  end

  # A batch's effects carry the row it saved; a batch that wrote nothing has none.
  defp saved_row({%Document{} = saved, _slug, _frame}, _doc), do: saved
  defp saved_row(_effects, doc), do: doc
end
