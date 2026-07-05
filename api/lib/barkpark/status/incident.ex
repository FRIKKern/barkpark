defmodule Barkpark.Status.Incident do
  @moduledoc """
  A public incident record shown on the status page. Walks the standard
  lifecycle (`investigating → identified → monitoring → resolved`); an
  unresolved incident degrades the overall reported status.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @impacts ~w(none minor major critical)
  @statuses ~w(investigating identified monitoring resolved)

  schema "status_incidents" do
    field :title, :string
    field :component, :string
    field :impact, :string, default: "minor"
    field :status, :string, default: "investigating"
    field :body, :string
    field :started_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The allowed impact severities, worst-last."
  def impacts, do: @impacts
  @doc "The allowed lifecycle statuses."
  def statuses, do: @statuses

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, [:title, :component, :impact, :status, :body, :started_at, :resolved_at])
    |> validate_required([:title, :impact, :status, :started_at])
    |> validate_inclusion(:impact, @impacts)
    |> validate_inclusion(:status, @statuses)
  end
end
