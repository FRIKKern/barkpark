defmodule Barkpark.CycleFleet.RuntimeAttempt do
  @moduledoc """
  Immutable authority binding one Task-backed CycleFleet assignment to its
  single managed Codex Studio session.

  The frozen claim identifies the lease that authorized the attempt. Provider
  events may mint assignment receipts only through this row.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "epic_assignment_runtime_attempts" do
    belongs_to :assignment, Barkpark.EpicFleet.Assignment, primary_key: true
    belongs_to :task, Barkpark.Content.Document
    belongs_to :session, Barkpark.StudioChat.Session
    field :task_worker_id, :string
    field :task_epoch, :integer
    field :task_work_digest, :string
    field :provider, :string
    field :execution_target, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "The exact Task claim attribution frozen when this attempt was authorized."
  def attribution(%__MODULE__{} = attempt) do
    %{
      assignment_id: attempt.assignment_id,
      task: %{
        id: attempt.task_id,
        worker_id: attempt.task_worker_id,
        epoch: attempt.task_epoch,
        work_digest: attempt.task_work_digest
      }
    }
  end
end
