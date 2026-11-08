defmodule Barkpark.Plugins.Barkbot.Executors.ClaudeCode do
  @moduledoc """
  Claude Code CLI executor.
  
  Executes jobs via the official `claude` CLI in programmatic mode (-p).
  Requires user to have authenticated via `claude setup-token`.
  
  ## Authentication
  
  - Never stores or passes CLAUDE_CODE_OAUTH_TOKEN
  - Assumes claude binary is already authenticated
  - Fails explicitly with auth_failed if not authenticated
  
  ## Workspace Isolation
  
  Each bot has its own workspace directory (bot.workspace_path).
  Claude Code runs with --cwd pointing to that workspace.
  
  ## Session Resume
  
  Multi-turn conversations use claude session IDs for context persistence.
  """
  
  @behaviour Barkpark.Plugins.Barkbot.Executor
  
  require Logger
  alias Barkpark.Plugins.Barkbot.{Job, Bot}
  
  @impl true
  def execute_job(job, bot) do
    with {:ok, adapter_path} <- get_adapter_path(),
         {:ok, workspace} <- ensure_workspace(bot),
         {:ok, output_path} <- prepare_output_path(job.id) do
      # Build command args
      args = build_args(job, bot, workspace, output_path)
      
      Logger.info("Executing Claude Code for job #{job.id}")
      Logger.debug("Args: #{inspect(args)}")
      
      # Execute adapter
      case run_adapter(adapter_path, args, job.timeout_seconds) do
        {:ok, pid, exit_code} ->
          handle_completion(output_path, pid, exit_code)
          
        {:error, :timeout} ->
          {:error, :timeout}
          
        {:error, reason} ->
          {:error, reason}
      end
    end
  end
  
  defp get_adapter_path do
    path = System.get_env("BARKBOT_CLAUDE_ADAPTER_PATH", "/usr/local/bin/barkbot-claude-adapter")
    
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, :adapter_not_found}
    end
  end
  
  defp ensure_workspace(bot) do
    workspace = bot.workspace_path || "/tmp/barkbot/workspaces/#{bot.bot_id}"
    
    case File.mkdir_p(workspace) do
      :ok -> {:ok, workspace}
      {:error, reason} -> {:error, {:workspace_error, reason}}
    end
  end
  
  defp prepare_output_path(job_id) do
    dir = System.tmp_dir!() |> Path.join("barkbot")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{job_id}.json")
    {:ok, path}
  end
  
  defp build_args(job, bot, workspace, output_path) do
    claude_bin = bot.claude_bin_path || "claude"
    
    base_args = [
      "--prompt", job.prompt,
      "--workspace", workspace,
      "--output", output_path,
      "--timeout", to_string(job.timeout_seconds),
      "--claude-bin", claude_bin
    ]
    
    # Add session ID if resuming conversation
    session_args =
      if job.conversation do
        case job.conversation.claude_session_id do
          nil -> []
          session_id -> ["--session-id", session_id]
        end
      else
        []
      end
    
    base_args ++ session_args
  end
  
  defp run_adapter(adapter_path, args, timeout_seconds) do
    port =
      Port.open(
        {:spawn_executable, adapter_path},
        [:binary, :exit_status, args: args]
      )
    
    pid = port_to_pid(port)
    timeout_ms = timeout_seconds * 1000
    
    receive do
      {^port, {:exit_status, exit_code}} ->
        {:ok, pid, exit_code}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :timeout}
    end
  end
  
  defp port_to_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end
  
  defp handle_completion(output_path, _pid, exit_code) do
    case {exit_code, File.read(output_path)} do
      {0, {:ok, json}} ->
        parse_success(json)
        
      {0, {:error, reason}} ->
        {:error, {:output_read_failed, reason}}
        
      {code, _} when code > 0 ->
        case File.read(output_path) do
          {:ok, json} -> parse_error(json)
          _ -> {:error, {:exit_code, code}}
        end
    end
  after
    File.rm(output_path)
  end
  
  defp parse_success(json) do
    case Jason.decode(json) do
      {:ok, result} ->
        {:ok,
         %{
           status: result["status"],
           response: result["response"],
           error: result["error"],
           tokens_used: nil,
           execution_time_ms: result["execution_time_ms"],
           session_id: result["session_id"]
         }}
        
      {:error, _} ->
        {:error, :invalid_output}
    end
  end
  
  defp parse_error(json) do
    case Jason.decode(json) do
      {:ok, result} ->
        status = Map.get(result, "status", "failed")
        error = Map.get(result, "error", "Unknown error")
        
        {:error, {:execution_failed, status, error}}
        
      {:error, _} ->
        {:error, :invalid_output}
    end
  end
end
