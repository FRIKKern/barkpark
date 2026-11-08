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
  
  use Barkpark.Plugin
  
  alias Barkpark.Plugins.Barkbot.{Bots, Jobs, Conversations}
  
  @impl true
  def register_schemas(repo) do
    # BarkBot uses PostgreSQL tables, not document types
    # Schema registration happens via migrations
    []
  end
  
  @impl true
  def register_routes(opts) do
    import Phoenix.Router
    
    scope "/barkbot", Barkpark.Plugins.Barkbot.Web, as: :barkbot do
      # Bot management (admin only)
      pipe_through [:browser, :require_admin]
      
      live "/", BotLive.Index, :index
      live "/bots/new", BotLive.New, :new
      live "/bots/:bot_id", BotLive.Show, :show
      live "/bots/:bot_id/settings", BotLive.Settings, :settings
      
      # Chat interface (write permission)
      pipe_through [:browser, :require_token]
      
      live "/chat", ChatLive.Index, :index
      live "/chat/:conversation_id", ChatLive.Show, :show
    end
    
    scope "/v1/plugins/barkbot", Barkpark.Plugins.Barkbot.Web, as: :barkbot_api do
      pipe_through [:api, :require_token]
      
      # Bot API (admin only for creation)
      post "/bots", BotController, :create
      get "/bots", BotController, :list
      get "/bots/:bot_id", BotController, :show
      patch "/bots/:bot_id", BotController, :update
      delete "/bots/:bot_id", BotController, :delete
      
      # Job API (write permission)
      post "/jobs", JobController, :create
      get "/jobs", JobController, :list
      get "/jobs/:job_id", JobController, :show
      post "/jobs/:job_id/cancel", JobController, :cancel
      
      # Conversation API
      post "/conversations", ConversationController, :create
      get "/conversations", ConversationController, :list
      get "/conversations/:id", ConversationController, :show
      post "/conversations/:id/messages", ConversationController, :add_message
    end
  end
  
  @impl true
  def capabilities do
    [
      %{
        "id" => "barkbot.create_bot",
        "name" => "Create BarkBot",
        "description" => "Create a new AI agent bot on this instance",
        "admin" => true
      },
      %{
        "id" => "barkbot.submit_job",
        "name" => "Submit Job",
        "description" => "Submit an AI task for execution",
        "admin" => false
      },
      %{
        "id" => "barkbot.chat",
        "name" => "Chat with Bot",
        "description" => "Interactive conversation with BarkBot",
        "admin" => false
      }
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
