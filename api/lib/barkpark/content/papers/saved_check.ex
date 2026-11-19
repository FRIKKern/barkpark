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
  """

  alias Barkpark.Content.{Broadcast, Document}
  alias Barkpark.Repo

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
                 :ok <- check.(saved_row(effects, doc)) do
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
      nil -> :ok
      check when is_function(check, 1) -> check.(doc)
    end
  end

  # A batch's effects carry the row it saved; a batch that wrote nothing has none.
  defp saved_row({%Document{} = saved, _slug, _frame}, _doc), do: saved
  defp saved_row(_effects, doc), do: doc
end
