defmodule Barkpark.Plugins.Barkbot.Runner do
  @moduledoc """
  Execute BarkBot jobs by invoking the external Go runner binary.
  
  The runner:
  - Calls LLM provider APIs (Anthropic, OpenAI, or mock)
  - Enforces timeouts
  - Handles cancellation (SIGTERM)
  - Returns structured JSON results
  - Runs as non-root user
  """
  
  require Logger
  import Ecto.Query
  alias Barkpark.Plugins.Barkbot.{Job, Bot, Jobs}
  
  @doc """
  Execute a job using the appropriate executor for its bot's provider.
  
  Returns {:ok, result} or {:error, reason}.
  """
  def execute_job(job_id) when is_binary(job_id) do
    alias Barkpark.Plugins.Barkbot.Executor
    
    with {:ok, job} <- Jobs.get_job(job_id),
         {:ok, bot} <- get_bot(job.bot_id) do
      # Mark job as running
      {:ok, job} = Jobs.start_job(job_id)
      
      # Execute using appropriate executor
      Logger.info("Starting BarkBot job #{job_id} with provider #{bot.provider}")
      
      case Executor.execute(job, bot) do
        {:ok, result} ->
          handle_success(job_id, result)
          
        {:error, :timeout} ->
          Logger.warning("BarkBot job #{job_id} timed out")
          Jobs.mark_timeout(job_id)
          {:error, :timeout}
          
        {:error, {:execution_failed, "auth_failed", error}} ->
          Logger.error("BarkBot job #{job_id} auth failed: #{error}")
          Jobs.mark_auth_failed(job_id, error)
          {:error, :auth_failed}
          
        {:error, {:execution_failed, "quota_exceeded", error}} ->
          Logger.warning("BarkBot job #{job_id} quota exceeded: #{error}")
          Jobs.mark_quota_exceeded(job_id, error)
          {:error, :quota_exceeded}
          
        {:error, reason} ->
          Logger.error("BarkBot job #{job_id} failed: #{inspect(reason)}")
          Jobs.mark_failed(job_id, "Execution failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
  
  defp get_bot(bot_id) do
    case Barkpark.Repo.get(Bot, bot_id) do
      nil -> {:error, :bot_not_found}
      bot -> {:ok, bot}
    end
  end
  
  defp handle_success(job_id, result) do
    response = result.response || ""
    tokens_used = result.tokens_used || 0
    execution_time_ms = result.execution_time_ms || 0
    session_id = result.session_id
    
    # Update job with results
    Jobs.mark_completed(job_id, response, tokens_used, execution_time_ms)
    
    # Update conversation session ID if present
    if session_id do
      update_conversation_session(job_id, session_id)
    end
    
    {:ok, result}
  end
  
  defp update_conversation_session(job_id, session_id) do
    with {:ok, job} <- Jobs.get_job(job_id),
         conversation_id when not is_nil(conversation_id) <- job.conversation_id do
      Barkpark.Repo.update_all(
        from(c in Barkpark.Plugins.Barkbot.Conversation, where: c.id == ^conversation_id),
        set: [claude_session_id: session_id, last_activity_at: DateTime.utc_now()]
      )
    end
  end
  
  @doc """
  Cancel a running job by sending SIGTERM to the runner process.
  """
  def cancel_job(job_id) when is_binary(job_id) do
    with {:ok, job} <- Jobs.get_job(job_id),
         true <- job.status == "running",
         pid when not is_nil(pid) <- job.runner_pid do
      Logger.info("Cancelling BarkBot job #{job_id}, killing PID #{pid}")
      
      # Send SIGTERM to runner process
      case System.cmd("kill", ["-TERM", to_string(pid)]) do
        {_, 0} ->
          Jobs.mark_cancelled(job_id)
          {:ok, :cancelled}
          
        {output, code} ->
          Logger.warning("Failed to kill process #{pid}: #{output} (code #{code})")
          {:error, :kill_failed}
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :not_running}
      nil -> {:error, :no_pid}
    end
  end
end
