defmodule Barkpark.Plugins.Barkbot.Bot do
  @moduledoc """
  Schema for BarkBot configuration.
  
  Each bot represents a persistent AI agent with:
  - Unique identity
  - LLM provider configuration
  - Encrypted API credentials
  - Workspace isolation
  - Computer identity (hostname, specs)
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  
  @providers ~w(claude-code anthropic-api openai-api mock)
  @production_providers ~w(claude-code anthropic-api openai-api)
  @statuses ~w(active inactive)
  @auth_statuses ~w(authenticated not_authenticated unknown error)
  
  @doc """
  Get allowed providers for current environment.
  Mock is only available in dev/test.
  """
  def allowed_providers do
    if Mix.env() == :prod do
      @production_providers
    else
      @providers
    end
  end
  
  schema "barkbot_bots" do
    field :bot_id, :string  # Slug identifier, e.g. "my-assistant"
    field :name, :string
    field :description, :string
    
    # Provider configuration
    field :provider, :string  # "claude-code" | "anthropic-api" | "openai-api" | "mock"
    field :model, :string     # e.g. "claude-3-5-sonnet-20241022" (for API providers)
    field :api_key_encrypted, :binary  # For API providers only
    
    # Claude Code specific
    field :claude_bin_path, :string  # Path to claude binary (default: "claude")
    field :workspace_path, :string   # Isolated workspace for this bot
    field :auth_status, :string, default: "unknown"  # "authenticated" | "not_authenticated" | "unknown"
    field :last_health_check_at, :utc_datetime_usec
    
    # Generation parameters
    field :max_tokens, :integer, default: 4096
    field :temperature, :float, default: 1.0
    field :system_prompt, :string
    
    # Limits
    field :timeout_seconds, :integer, default: 300  # 5 minutes
    field :max_concurrent_jobs, :integer, default: 1
    
    # Computer identity
    field :hostname, :string
    field :cpu_cores, :integer
    field :memory_gb, :integer
    field :location, :string  # e.g. "Hetzner Nuremberg"
    
    # Status
    field :status, :string, default: "active"
    field :enabled, :boolean, default: true
    field :last_active_at, :utc_datetime_usec
    
    # Workspace isolation
    field :workspace_id, :binary_id
    
    timestamps(type: :utc_datetime_usec)
  end
  
  def changeset(bot, attrs) do
    bot
    |> cast(attrs, [
      :bot_id,
      :name,
      :description,
      :provider,
      :model,
      :max_tokens,
      :temperature,
      :system_prompt,
      :timeout_seconds,
      :max_concurrent_jobs,
      :hostname,
      :cpu_cores,
      :memory_gb,
      :location,
      :status,
      :enabled,
      :workspace_id,
      :claude_bin_path,
      :workspace_path,
      :auth_status,
      :last_health_check_at
    ])
    |> validate_required([:bot_id, :name, :provider, :workspace_id])
    |> validate_inclusion(:provider, allowed_providers())
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:auth_status, @auth_statuses)
    |> validate_number(:max_tokens, greater_than: 0, less_than_or_equal_to: 200_000)
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:timeout_seconds, greater_than: 0, less_than_or_equal_to: 3600)
    |> validate_number(:max_concurrent_jobs, greater_than: 0, less_than_or_equal_to: 10)
    |> unique_constraint(:bot_id)
    |> unique_constraint([:bot_id, :workspace_id])
  end
  
  def create_changeset(bot, attrs, api_key) do
    bot
    |> changeset(attrs)
    |> put_change(:api_key_encrypted, encrypt_api_key(api_key))
  end
  
  @doc """
  Encrypt API key using Cloak or similar.
  For prototype, we'll use a simple approach.
  """
  def encrypt_api_key(nil), do: nil
  def encrypt_api_key(key) when is_binary(key) do
    # In production, use Cloak.Ecto or proper encryption
    # For prototype, we'll just store it (NOT SECURE - placeholder only)
    Base.encode64(key)
  end
  
  @doc """
  Decrypt API key.
  """
  def decrypt_api_key(nil), do: nil
  def decrypt_api_key(encrypted) when is_binary(encrypted) do
    Base.decode64!(encrypted)
  end
end
