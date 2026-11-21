defmodule Barkpark.Plugins.Barkbot do
  @moduledoc """
  BarkBot plugin - enables each Barkpark instance to function as a persistent
  AI agent with its own dedicated computer.
  
  ## Architecture
  
  Each BarkBot is a Barkpark instance with:
  - Dedicated Hetzner server (1 bot = 1 computer)
  - Persistent identity and configuration
  - Job queue for AI task execution
  - Configurable LLM provider (Anthropic Claude, OpenAI GPT)
  - Web UI for interaction
  
  ## Components
  
  - `Barkbot.Jobs` - Job queue and lifecycle management
  - `Barkbot.Bots` - Bot configuration and secrets
  - `Barkbot.Runner` - Execute jobs via external Go binary
  - `Barkbot.Web` - LiveView interface matching Grok Bot layout
  """
  
  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/barkbot/plugin.json"
  
  alias Barkpark.Plugins.Barkbot.{Bots, Jobs, Conversations}
  
  @impl Barkpark.Plugin
  def register_schemas(_ctx) do
    []
  end
  
  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    bot_controller = Barkpark.Plugins.Barkbot.Web.BotController
    job_controller = Barkpark.Plugins.Barkbot.Web.JobController
    chat_live = Barkpark.Plugins.Barkbot.Web.ChatLive
    
    [
      {:get, "/v1/barkbot/bots", bot_controller, :index, auth: :token},
      {:post, "/v1/barkbot/bots", bot_controller, :create, auth: :token},
      {:get, "/v1/barkbot/bots/:id", bot_controller, :show, auth: :token},
      {:put, "/v1/barkbot/bots/:id", bot_controller, :update, auth: :token},
      {:delete, "/v1/barkbot/bots/:id", bot_controller, :delete, auth: :token},
      
      {:get, "/v1/barkbot/jobs", job_controller, :index, auth: :token},
      {:post, "/v1/barkbot/jobs", job_controller, :create, auth: :token},
      {:get, "/v1/barkbot/jobs/:id", job_controller, :show, auth: :token},
      
      {:live, "/barkbot/chat", chat_live, :index, auth: :token},
      {:live, "/barkbot/chat/:bot_id", chat_live, :show, auth: :token}
    ]
  end
  
  @doc """
  Check if BarkBot is enabled and runner binary is available.
  """
  def enabled? do
    Application.get_env(:barkpark, :plugins, [])
    |> Enum.member?(:barkbot)
  end
  
  @doc """
  Get the runner binary path. Returns {:ok, path} or {:error, :not_found}.
  """
  def runner_path do
    path = System.get_env("BARKBOT_RUNNER_PATH", "/usr/local/bin/barkbot-runner")
    
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end
end
