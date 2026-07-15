defmodule Barkpark.CycleFleet.AssignmentTask do
  @moduledoc """
  Immutable server-owned binding between one CycleFleet assignment and one Task.

  Runtime evidence may reference the pair only after dispatch has frozen this
  row. The database rejects rebinding, updates, and deletes.
  """

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "epic_assignment_tasks" do
    belongs_to :assignment, Barkpark.EpicFleet.Assignment, primary_key: true
    belongs_to :task, Barkpark.Content.Document
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
