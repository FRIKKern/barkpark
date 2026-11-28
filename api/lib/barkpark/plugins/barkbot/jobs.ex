defmodule Barkpark.Plugins.Barkbot.Jobs do
  @moduledoc """
  Context for managing BarkBot jobs.
  """
  
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Plugins.Barkbot.Job
  
  @doc """
  Create a new job.
  """
  def create_job(attrs) do
    %Job{}
    |> Job.create_changeset(attrs)
    |> Repo.insert()
  end
  
  @doc """
  Get a job by ID.
  """
  def get_job(id) do
    case Repo.get(Job, id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end
  
  @doc """
  List jobs, optionally filtered by bot_id or workspace_id.
  """
  def list_jobs(filters \\ %{}) do
    Job
    |> apply_filters(filters)
    |> order_by([j], desc: j.inserted_at)
    |> Repo.all()
  end
  
  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:bot_id, bot_id}, q when not is_nil(bot_id) ->
        where(q, [j], j.bot_id == ^bot_id)
        
      {:workspace_id, workspace_id}, q when not is_nil(workspace_id) ->
        where(q, [j], j.workspace_id == ^workspace_id)
        
      {:conversation_id, conversation_id}, q when not is_nil(conversation_id) ->
        where(q, [j], j.conversation_id == ^conversation_id)
        
      {:status, status}, q when not is_nil(status) ->
        where(q, [j], j.status == ^status)
        
      _, q ->
        q
    end)
  end
  
  @doc """
  Mark a job as running.
  """
  def start_job(job_id) do
    with {:ok, job} <- get_job(job_id) do
      job
      |> Job.start_changeset()
      |> Repo.update()
    end
  end
  
  @doc """
  Mark a job as completed with results.
  """
  def mark_completed(job_id, response, tokens_used, execution_time_ms) do
    with {:ok, job} <- get_job(job_id) do
      job
      |> Job.complete_changeset(response, tokens_used, execution_time_ms)
      |> Repo.update()
    end
  end
  
  @doc """
  Mark a job as failed with error.
  """
  def mark_failed(job_id, error) do
    with {:ok, job} <- get_job(job_id) do
      job
      |> Job.fail_changeset(error)
      |> Repo.update()
    end
  end
  
  @doc """
  Mark a job as cancelled.
  """
  def mark_cancelled(job_id) do
    with {:ok, job} <- get_job(job_id) do
      job
      |> Job.cancel_changeset()
      |> Repo.update()
    end
  end
  
  @doc """
  Mark a job as timed out.
  """
  def mark_timeout(job_id) do
    with {:ok, job} <- get_job(job_id) do
      job
      |> Job.timeout_changeset()
      |> Repo.update()
    end
  end
  
  @doc """
  Mark a job as authentication failed.
  """
  def mark_auth_failed(job_id, error) do
    with {:ok, job} <- get_job(job_id) do
      job
      |> Ecto.Changeset.change(
        status: "auth_failed",
        completed_at: DateTime.utc_now(),
        error: error
      )
      |> Repo.update()
    end
  end
  
  @doc """
  Mark a job as quota exceeded.
  """
  def mark_quota_exceeded(job_id, error) do
    with {:ok, job} <- get_job(job_id) do
      job
      |> Ecto.Changeset.change(
        status: "quota_exceeded",
        completed_at: DateTime.utc_now(),
        error: error
      )
      |> Repo.update()
    end
  end
  
  @doc """
  Request cancellation for a job.
  """
  def request_cancel(job_id) do
    with {:ok, job} <- get_job(job_id) do
      job
      |> Ecto.Changeset.change(cancel_requested: true)
      |> Repo.update()
    end
  end
end
