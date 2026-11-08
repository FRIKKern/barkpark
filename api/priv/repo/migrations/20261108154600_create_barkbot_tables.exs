defmodule Barkpark.Repo.Migrations.CreateBarkbotTables do
  use Ecto.Migration

  def up do
    # Bots table
    create table(:barkbot_bots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bot_id, :string, null: false
      add :name, :string, null: false
      add :description, :text
      
      # Provider configuration
      add :provider, :string, null: false
      add :model, :string
      add :api_key_encrypted, :binary
      
      # Claude Code specific
      add :claude_bin_path, :string
      add :workspace_path, :string
      add :auth_status, :string, default: "unknown"
      add :last_health_check_at, :utc_datetime_usec
      
      # Generation parameters
      add :max_tokens, :integer, default: 4096
      add :temperature, :float, default: 1.0
      add :system_prompt, :text
      
      # Limits
      add :timeout_seconds, :integer, default: 300
      add :max_concurrent_jobs, :integer, default: 1
      
      # Computer identity
      add :hostname, :string
      add :cpu_cores, :integer
      add :memory_gb, :integer
      add :location, :string
      
      # Status
      add :status, :string, default: "active"
      add :enabled, :boolean, default: true
      add :last_active_at, :utc_datetime_usec
      
      # Workspace isolation
      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false
      
      timestamps(type: :utc_datetime_usec)
    end
    
    create unique_index(:barkbot_bots, [:bot_id])
    create unique_index(:barkbot_bots, [:bot_id, :workspace_id])
    create index(:barkbot_bots, [:workspace_id])
    create index(:barkbot_bots, [:status])
    create index(:barkbot_bots, [:enabled])
    
    # Conversations table
    create table(:barkbot_conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bot_id, references(:barkbot_bots, on_delete: :delete_all, type: :binary_id),
        null: false
      add :title, :string
      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false
      add :created_by, :string
      add :last_message_at, :utc_datetime_usec
      
      # Claude Code session tracking
      add :claude_session_id, :string
      add :last_activity_at, :utc_datetime_usec
      
      timestamps(type: :utc_datetime_usec)
    end
    
    create index(:barkbot_conversations, [:bot_id])
    create index(:barkbot_conversations, [:workspace_id])
    create index(:barkbot_conversations, [:last_message_at])
    
    # Messages table
    create table(:barkbot_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id,
        references(:barkbot_conversations, on_delete: :delete_all, type: :binary_id),
        null: false
      add :job_id, references(:barkbot_jobs, on_delete: :nilify_all, type: :binary_id)
      add :role, :string, null: false
      add :content, :text, null: false
      add :tokens, :integer
      
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    
    create index(:barkbot_messages, [:conversation_id])
    create index(:barkbot_messages, [:job_id])
    
    # Jobs table
    create table(:barkbot_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :bot_id, references(:barkbot_bots, on_delete: :delete_all, type: :binary_id),
        null: false
      add :conversation_id,
        references(:barkbot_conversations, on_delete: :nilify_all, type: :binary_id)
      
      # Input
      add :prompt, :text, null: false
      add :system_prompt, :text
      add :max_tokens, :integer
      add :temperature, :float
      add :timeout_seconds, :integer
      
      # Lifecycle
      add :status, :string, default: "pending", null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :cancel_requested, :boolean, default: false
      
      # Output
      add :response, :text
      add :error, :text
      add :tokens_used, :integer
      add :execution_time_ms, :integer
      
      # Runner tracking
      add :runner_pid, :integer
      add :runner_output_path, :string
      
      # Audit
      add :created_by, :string
      add :workspace_id, references(:workspaces, on_delete: :delete_all, type: :binary_id),
        null: false
      
      timestamps(type: :utc_datetime_usec)
    end
    
    create index(:barkbot_jobs, [:bot_id])
    create index(:barkbot_jobs, [:conversation_id])
    create index(:barkbot_jobs, [:workspace_id])
    create index(:barkbot_jobs, [:status])
    create index(:barkbot_jobs, [:started_at])
    create index(:barkbot_jobs, [:cancel_requested])
    
    # Fix circular reference - add job_id to messages after jobs table exists
    # (Already added above in messages table creation)
  end

  def down do
    drop table(:barkbot_jobs)
    drop table(:barkbot_messages)
    drop table(:barkbot_conversations)
    drop table(:barkbot_bots)
  end
end
