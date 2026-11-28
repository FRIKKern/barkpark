defmodule Barkpark.Plugins.Barkbot.Queue do
  @moduledoc """
  Job queue with throttling to respect Claude subscription limits.
  
  Enforces:
  - Maximum concurrent jobs across entire installation
  - Minimum spacing between job starts
  - Honest capacity reporting
  """
  
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Plugins.Barkbot.Job
  
  # Conservative defaults for subscription limits
  @max_concurrent_jobs 2
  @min_job_spacing_ms 5_000
  
  @doc """
  Check if a new job can start.
  
  Returns :ok if can start, {:error, :throttled} if must wait.
  """
  def can_start_job?(_bot_id) do
    running_count = count_running_jobs()
    last_start_time = get_last_job_start_time()
    
    cond do
      running_count >= @max_concurrent_jobs ->
        {:error, :throttled}
        
      last_start_time && time_since(last_start_time) < @min_job_spacing_ms ->
        {:error, :throttled}
        
      true ->
        :ok
    end
  end
  
  @doc """
  Count currently running jobs across entire system.
  """
  def count_running_jobs do
    Job
    |> where([j], j.status == "running")
    |> Repo.aggregate(:count)
  end
  
  @doc """
  Get the most recent job start time.
  """
  def get_last_job_start_time do
    Job
    |> where([j], not is_nil(j.started_at))
    |> order_by([j], desc: j.started_at)
    |> limit(1)
    |> select([j], j.started_at)
    |> Repo.one()
  end
  
  @doc """
  Get queue statistics.
  """
  def get_stats do
    %{
      running: count_running_jobs(),
      pending: count_by_status("pending"),
      throttled: count_by_status("throttled"),
      max_concurrent: @max_concurrent_jobs,
      min_spacing_ms: @min_job_spacing_ms,
      last_start: get_last_job_start_time()
    }
  end
  
  defp count_by_status(status) do
    Job
    |> where([j], j.status == ^status)
    |> Repo.aggregate(:count)
  end
  
  defp time_since(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :millisecond)
  end
end
