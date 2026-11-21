defmodule Barkpark.Plugins.Barkbot.Executor do
  @moduledoc """
  Abstraction for different execution backends (Claude Code, API providers, mock).
  
  Each executor implements the execute_job/1 callback and returns a standardized result.
  """
  
  alias Barkpark.Plugins.Barkbot.{Job, Bot}
  
  @type result :: %{
          status: String.t(),
          response: String.t() | nil,
          error: String.t() | nil,
          tokens_used: integer() | nil,
          execution_time_ms: integer(),
          session_id: String.t() | nil
        }
  
  @callback execute_job(job :: Job.t(), bot :: Bot.t()) :: {:ok, result()} | {:error, term()}
  
  @doc """
  Get the appropriate executor for a bot's provider.
  """
  def get_executor(bot) do
    case bot.provider do
      "claude-code" -> Barkpark.Plugins.Barkbot.Executors.ClaudeCode
      "anthropic-api" -> Barkpark.Plugins.Barkbot.Executors.AnthropicAPI
      "openai-api" -> Barkpark.Plugins.Barkbot.Executors.OpenAIAPI
      "mock" -> Barkpark.Plugins.Barkbot.Executors.Mock
      _ -> {:error, :unknown_provider}
    end
  end
  
  @doc """
  Execute a job using the appropriate executor for its bot.
  """
  def execute(job, bot) do
    case get_executor(bot) do
      {:error, reason} ->
        {:error, reason}
        
      executor_module ->
        executor_module.execute_job(job, bot)
    end
  end
end
