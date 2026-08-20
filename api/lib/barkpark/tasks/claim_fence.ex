defmodule Barkpark.Tasks.ClaimFence do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @type reason ::
          :task_not_found
          | :task_not_claimed
          | :task_doc_mismatch
          | :task_workspace_mismatch
          | :task_project_mismatch
          | :task_dataset_mismatch
          | :foreign_claim
          | :stale_claim
          | :work_digest_mismatch

  @doc "Validate one live Task lease without renewing or mutating it."
  @spec verify(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, reason()}
  def verify(task_id, expected) when is_binary(task_id) and is_map(expected) do
    # Cast before the query: `id` is the Document :binary_id PK, and a non-UUID
    # binary would RAISE Ecto.Query.CastError, violating the {:ok,_}|{:error,_}
    # contract. A non-UUID can never name a live task — collapse it to
    # :task_not_found (the same reason the catch-all clause returns).
    case Ecto.UUID.cast(task_id) do
      {:ok, id} ->
        case Repo.one(
               from(d in Document,
                 where: d.id == ^id and d.type == "task",
                 lock: "FOR SHARE"
               )
             ) do
          nil -> {:error, :task_not_found}
          %Document{} = task -> verify_task(task, expected)
        end

      :error ->
        {:error, :task_not_found}
    end
  end

  def verify(_task_id, _expected), do: {:error, :task_not_found}

  defp verify_task(%Document{} = task, expected) do
    content = task.content || %{}
    claim = Map.get(content, "claim") || %{}
    expected_doc_id = value(expected, :doc_id)
    expected_worker = value(expected, :worker_id)
    expected_epoch = value(expected, :epoch)
    expected_digest = value(expected, :work_digest)
    expected_workspace_id = value(expected, :workspace_id)
    expected_project_id = value(expected, :project_id)
    expected_dataset_id = value(expected, :dataset_id)

    cond do
      Map.get(content, "lifecycle_status") != "in_progress" or
          not is_binary(Map.get(claim, "worker")) ->
        {:error, :task_not_claimed}

      task.doc_id != expected_doc_id ->
        {:error, :task_doc_mismatch}

      task.workspace_id != expected_workspace_id ->
        {:error, :task_workspace_mismatch}

      task.project_id != expected_project_id ->
        {:error, :task_project_mismatch}

      task.dataset_id != expected_dataset_id ->
        {:error, :task_dataset_mismatch}

      Map.get(claim, "worker") != expected_worker ->
        {:error, :foreign_claim}

      Map.get(claim, "epoch") != expected_epoch ->
        {:error, :stale_claim}

      Map.get(claim, "work_digest") != expected_digest ->
        {:error, :work_digest_mismatch}

      true ->
        {:ok,
         %{
           task_id: task.id,
           task_doc_id: task.doc_id,
           task_worker_id: Map.fetch!(claim, "worker"),
           task_epoch: Map.fetch!(claim, "epoch"),
           task_work_digest: Map.fetch!(claim, "work_digest")
         }}
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))
end
