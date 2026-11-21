defmodule Barkpark.Plugins.Barkbot.Job do
  @moduledoc """
  Schema for BarkBot jobs.
  
  A job represents a single AI task execution with:
  - Lifecycle tracking (pending → running → completed/failed/cancelled)
  - Input prompt and parameters
  - Output response and metadata
  - Execution metrics
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  
  @statuses ~w(pending throttled running completed failed auth_failed quota_exceeded timeout cancelled)
  
  schema "barkbot_jobs" do
    # Association
    belongs_to :bot, Barkpark.Plugins.Barkbot.Bot, type: :binary_id
    belongs_to :conversation, Barkpark.Plugins.Barkbot.Conversation, type: :binary_id
    
    # Input
    field :prompt, :string
    field :system_prompt, :string
    field :max_tokens, :integer
    field :temperature, :float
    field :timeout_seconds, :integer
    
    # Lifecycle
    field :status, :string, default: "pending"
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :cancel_requested, :boolean, default: false
    
    # Output
    field :response, :string
    field :error, :string
    field :tokens_used, :integer
    field :execution_time_ms, :integer
    
    # Runner process tracking
    field :runner_pid, :integer
    field :runner_output_path, :string
    
    # Audit
    field :created_by, :string
    field :workspace_id, :binary_id
    
    timestamps(type: :utc_datetime_usec)
  end
  
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :bot_id,
      :conversation_id,
      :prompt,
      :system_prompt,
      :max_tokens,
      :temperature,
      :timeout_seconds,
      :status,
      :started_at,
      :completed_at,
      :cancelled_at,
      :cancel_requested,
      :response,
      :error,
      :tokens_used,
      :execution_time_ms,
      :runner_pid,
      :runner_output_path,
      :created_by,
      :workspace_id
    ])
    |> validate_required([:bot_id, :prompt, :workspace_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:max_tokens, greater_than: 0)
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0)
    |> validate_length(:prompt, min: 1, max: 100_000)
    |> foreign_key_constraint(:bot_id)
    |> foreign_key_constraint(:conversation_id)
  end
  
  def create_changeset(job, attrs) do
    job
    |> changeset(attrs)
    |> put_change(:status, "pending")
  end
  
  def start_changeset(job) do
    job
    |> change(status: "running", started_at: DateTime.utc_now())
  end
  
  def complete_changeset(job, response, tokens_used, execution_time_ms) do
    job
    |> change(
      status: "completed",
      completed_at: DateTime.utc_now(),
      response: response,
      tokens_used: tokens_used,
      execution_time_ms: execution_time_ms
    )
  end
  
  def fail_changeset(job, error) do
    job
    |> change(
      status: "failed",
      completed_at: DateTime.utc_now(),
      error: error
    )
  end
  
  def cancel_changeset(job) do
    job
    |> change(
      status: "cancelled",
      cancelled_at: DateTime.utc_now(),
      cancel_requested: true
    )
  end
  
  def timeout_changeset(job) do
    job
    |> change(
      status: "timeout",
      completed_at: DateTime.utc_now(),
      error: "Job exceeded timeout limit"
    )
  end
end
