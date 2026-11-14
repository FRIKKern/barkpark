defmodule Barkpark.Plugins.Barkbot.Authorization do
  @moduledoc """
  Authorization checks for BarkBot resources.
  
  Ensures users can only access bots and jobs in their workspace.
  """
  
  alias Barkpark.Plugins.Barkbot.{Bot, Job}
  
  @doc """
  Check if user can access a bot.
  
  Returns :ok if authorized, {:error, :forbidden} otherwise.
  """
  def authorize_bot_access(conn, %Bot{workspace_id: bot_workspace_id}) do
    user_workspace_id = conn.assigns.current_workspace.id
    
    if bot_workspace_id == user_workspace_id do
      :ok
    else
      {:error, :forbidden}
    end
  end
  
  @doc """
  Check if user can access a job.
  
  Returns :ok if authorized, {:error, :forbidden} otherwise.
  """
  def authorize_job_access(conn, %Job{workspace_id: job_workspace_id}) do
    user_workspace_id = conn.assigns.current_workspace.id
    
    if job_workspace_id == user_workspace_id do
      :ok
    else
      {:error, :forbidden}
    end
  end
  
  @doc """
  Check if user is admin.
  
  Returns :ok if admin, {:error, :forbidden} otherwise.
  """
  def require_admin(conn) do
    if conn.assigns[:current_user_admin] || conn.assigns[:is_admin] do
      :ok
    else
      {:error, :forbidden}
    end
  end
  
  @doc """
  Filter bots to only those in user's workspace.
  """
  def scope_bots_to_workspace(query, workspace_id) do
    import Ecto.Query
    where(query, [b], b.workspace_id == ^workspace_id)
  end
  
  @doc """
  Filter jobs to only those in user's workspace.
  """
  def scope_jobs_to_workspace(query, workspace_id) do
    import Ecto.Query
    where(query, [j], j.workspace_id == ^workspace_id)
  end
end
