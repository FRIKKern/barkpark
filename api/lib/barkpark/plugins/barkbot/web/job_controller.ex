defmodule Barkpark.Plugins.Barkbot.Web.JobController do
  use BarkparkWeb, :controller
  
  alias Barkpark.Plugins.Barkbot.{Jobs, Job, Bots, Authorization, Queue}
  
  def create(conn, params) do
    workspace_id = conn.assigns.current_workspace.id
    
    # Verify bot access
    with {:ok, bot} <- Bots.get_bot(params["bot_id"]),
         :ok <- Authorization.authorize_bot_access(conn, bot),
         :ok <- Queue.can_start_job?(bot.id) do
      
      job_params = Map.merge(params, %{
        "workspace_id" => workspace_id,
        "created_by" => get_user_email(conn)
      })
      
      case Jobs.create_job(job_params) do
        {:ok, job} ->
          # Start execution asynchronously
          Task.start(fn ->
            Barkpark.Plugins.Barkbot.Runner.execute_job(job.id)
          end)
          
          conn
          |> put_status(:created)
          |> json(sanitize_job(job))
          
        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Bot not found"})
        
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Access denied"})
        
      {:error, :throttled} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many concurrent jobs, please wait"})
    end
  end
  
  def list(conn, params) do
    workspace_id = conn.assigns.current_workspace.id
    
    filters = Map.merge(params, %{"workspace_id" => workspace_id})
    jobs = Jobs.list_jobs(filters)
    
    json(conn, %{jobs: Enum.map(jobs, &sanitize_job/1)})
  end
  
  def show(conn, %{"job_id" => job_id}) do
    with {:ok, job} <- Jobs.get_job(job_id),
         :ok <- Authorization.authorize_job_access(conn, job) do
      json(conn, sanitize_job(job))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found"})
        
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Access denied"})
    end
  end
  
  def cancel(conn, %{"job_id" => job_id}) do
    with {:ok, job} <- Jobs.get_job(job_id),
         :ok <- Authorization.authorize_job_access(conn, job),
         {:ok, _} <- Barkpark.Plugins.Barkbot.Runner.cancel_job(job_id) do
      json(conn, %{status: "cancelled"})
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found"})
        
      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Access denied"})
        
      {:error, :not_running} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Job is not running"})
    end
  end
  
  defp sanitize_job(job) do
    job
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__struct__])
  end
  
  defp get_user_email(conn) do
    conn.assigns[:current_user][:email] || "unknown"
  end
  
  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
