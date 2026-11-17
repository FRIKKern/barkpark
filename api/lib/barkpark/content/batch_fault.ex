defmodule Barkpark.Content.BatchFault do
  @moduledoc """
  Test-only fault seams for the mutate batch (`Barkpark.Content.Mutations`),
  driven by the same `:writer_fault` config `Content.Writer` reads. `nil`
  outside tests: one `Application.get_env` per batch.

  The SQL sandbox cannot produce a real pool shed or a connection lost at
  commit, so a test raises the exception the live run carried, at the point it
  was raised:

    * `{:batch_transaction, module, message}` raises inside the batch
      transaction, before any write.
    * `{:batch_rollback, %DBConnection.ConnectionError{}}` rolls the batch back
      with that struct as its reason (task-61dbf8a21cd155d1).
    * `{:after_commit, module, message}` raises right after the batch
      transaction committed: the answer the client gets is a fault although
      the write landed (task-717c91a6e9b6758b).
  """

  alias Barkpark.Repo

  @doc "The in-transaction seam, run before the batch's first write."
  def before_write! do
    case Application.get_env(:barkpark, :writer_fault) do
      {:batch_transaction, module, message} when is_atom(module) and is_binary(message) ->
        raise module, message

      {:batch_rollback, %DBConnection.ConnectionError{} = e} ->
        Repo.rollback(e)

      _ ->
        :ok
    end
  end

  @doc "The post-commit seam, run once the batch transaction returned `{:ok, _}`."
  def after_commit! do
    case Application.get_env(:barkpark, :writer_fault) do
      {:after_commit, module, message} when is_atom(module) and is_binary(message) ->
        raise module, message

      _ ->
        :ok
    end
  end
end
