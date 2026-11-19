defmodule Barkpark.Content.Papers.SavedCheck do
  @moduledoc """
  A caller's check of a Paper as saved, run inside the write's transaction.

  The check rides the write's opts as `before_commit:`, a 0-arity function
  that answers `:ok` or `{:error, reason}`; it reads what it needs itself, and
  inside the transaction it reads the row as written. On `{:error, reason}`
  the write rolls back and answers that error: the row, its rev, its cache and
  its history row stay as they were, and the effects a write runs after its
  commit (broadcasts, the edge projection, change events) never run. A write
  without the option is unchanged.
  """

  alias Barkpark.Content.Broadcast
  alias Barkpark.Repo

  @doc """
  A block-op batch's persist (`{:ok, receipt, effects}` or `{:error, _}`),
  run with the check before it commits. A batch that wrote nothing is still
  checked. The transaction owns the deferred broadcast queue
  (`Broadcast.with_deferred_queue/1`), so anything the persist queues is sent
  on commit and dropped on a refusal.
  """
  @spec batch(keyword(), (-> {:ok, term(), term()} | {:error, term()})) ::
          {:ok, term(), term()} | {:error, term()}
  def batch(opts, persist) when is_function(persist, 0) do
    case Keyword.get(opts, :before_commit) do
      nil ->
        persist.()

      check when is_function(check, 0) ->
        Broadcast.with_deferred_queue(fn ->
          Repo.transaction(fn ->
            with {:ok, receipt, effects} <- persist.(),
                 :ok <- check.() do
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

  @doc "The check, for a write whose transaction is already open: `:ok` without one."
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    case Keyword.get(opts, :before_commit) do
      nil -> :ok
      check when is_function(check, 0) -> check.()
    end
  end
end
